{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Servus.Server where

import           Control.Applicative
import           Control.Concurrent.STM
import           Control.Monad
import           Control.Monad.Reader
import           Data.Digest.Human               (humanHash)
import 		 Data.List                       (sortBy, groupBy)
import qualified Data.Map.Strict         as M
import qualified Data.Set                as S
import           Data.Text                       (Text)
import qualified Data.Text               as T
import           Data.Text.Encoding              (encodeUtf8)   
import           Data.Time.Clock                 (diffUTCTime)
import           Data.UUID.V4                    (nextRandom)
import qualified Data.UUID               as UUID
import           System.Mesos.Types              (TaskInfo (..), Offer (..), Status, TaskID (..), SlaveID (..), OfferID (..))
import qualified System.Mesos.Types      as MT

import           Servus.Config
import           Servus.Task

data ServerState = ServerState
    { _conf     :: ServusConf                         -- ^ Parsed server configuration
    , _library  :: TVar TaskLibrary                   -- ^ Task library is updated via REST API and during config
--    , _nursery  :: TChan (Task Warmup)                -- ^ The task nursery holds new task instances which were triggered remotely
    , _bullpen  :: TVar (S.Set (Task Ready))          -- ^ Task bullpen holds instances awaiting offers from mesos
    , _arena    :: TVar (M.Map TaskID (Task Running)) -- ^ Task arean holds launched instances
    , _mortuary :: TChan (Task Finished)              -- ^ Task mortuary holds terminal task instances
    }

instance Ord TaskID where
    (TaskID a) `compare` (TaskID b) = a `compare` b

instance Ord SlaveID where
    (SlaveID a) `compare` (SlaveID b) = a `compare` b

newServerState :: ServusConf -> IO ServerState
newServerState _conf = do
    _library  <- newTVarIO $ newTaskLibrary _conf
    _nursery  <- newTChanIO
    _bullpen  <- newTVarIO S.empty
    _arena    <- newTVarIO M.empty
    _mortuary <- newTChanIO
    return ServerState {..}

newtype TaskM a = TaskM { runTaskM :: ReaderT ServerState IO a }
  deriving (Applicative, Functor, Monad, MonadIO, MonadReader ServerState)

taskM :: MonadTrans t => TaskM a -> t TaskM a
taskM = lift

-- | Generate a TaskID using a human hash of a random UUID
randomTaskID :: TaskConf -> IO TaskID
randomTaskID tc = nextRandom >>= return . TaskID . textEncode . taskIdGen
  where
    textEncode = encodeUtf8 . T.append (flip T.snoc '.' $ _tcName tc) . T.intercalate "_"
    taskIdGen = humanHash 5 . UUID.toString

-- | Obtain the 'TaskLibrary' from the 'ServerState'
getTaskLibrary :: ServerState -> IO TaskLibrary
getTaskLibrary = atomically . readTVar . _library

-- | Get a 'TaskConf' from the 'TaskLibrary' if it exists, otherwise 'Nothing'
getTaskConf :: TaskName -> ServerState -> IO (Maybe TaskConf)
getTaskConf name server = getTaskLibrary server >>= return . flip lookupTaskConf name

-- | Put a 'TaskConf' into the 'TaskLibrary' if a previous version exists
-- it will be returned by the function
putTaskConf :: TaskConf -> ServerState -> IO (Maybe TaskConf)
putTaskConf conf server = atomically $ do
    let tvar = _library server
    library <- readTVar tvar
    let (conf', library') = insertLookupTaskConf library conf
    writeTVar tvar library'
    return conf'

-- | Put a 'TaskConf' into the bullpen to await offers
-- If the current environment cannot accept the task an
-- error will be reported Left, otherwise the taskId of the 
-- accepted task will be returned Right
runTaskConf :: TaskConf -> ServerState -> IO (Either Text TaskID)
runTaskConf conf server = do
    let tvar = _bullpen server
    bullpen <- readTVarIO tvar
    tid     <- randomTaskID conf
    task    <- newTask conf tid
    if canRun task bullpen
        then atomically $ do
            modifyTVar' tvar (S.insert task) 
            return $ Right tid
        else return $ Left "Cannot run task..."
  where
    canRun task          = null . (takeWhile ((checkLaunchRate task) . (diffReadyTime task))) . (dropOthers task) . S.toAscList
    dropOthers task      = dropWhile ((/= (_tcName $ _tConf task)) . _tcName . _tConf)
    diffReadyTime task   = realToFrac . (flip diffUTCTime (_tsReadyTime $ _tSched task)) . _tsReadyTime . _tSched
    checkLaunchRate task = (< (_tcLaunchRate $ _tcTrigger $ _tConf task))

-- | Find the first match in the bullpen for the given offers
-- returns a list of lists, where each sub-list is a list of
-- offer task pairs, where all offers are for the same slave
matchOffers :: [Offer] -> ServerState -> IO [[ReadyOffer]]
matchOffers offers server = do
    let tvar = _bullpen server
    bullpen <- readTVarIO tvar
    -- TODO: Really implement matching
    return $ groupBy eqSlaveId $ sortBy ordSlaveId $ zip offers $ (map Just $ S.toAscList bullpen) ++ (repeat Nothing) -- ^ offers paired with Nothing are discarded
  where
    getSlaveId = offerSlaveID . fst
    ordSlaveId x y = getSlaveId x `compare` getSlaveId y
    eqSlaveId x y = getSlaveId x == getSlaveId y

-- | Aliaases to make runTasks types easier
type ReadyOffer       = (Offer, Maybe (Task Ready))
type RunningOffer     = (Offer, TaskInfo)
type OfferAssignments = ([RunningOffer], [Offer])

-- | Run tasks which have been given offers.
-- Tasks are removed from the bullpen and put into the arena
runTasks :: [ReadyOffer] -> ServerState -> ([OfferID] -> [TaskInfo] -> IO Status) -> IO Status
runTasks pairs server f = do
    (ready, un) <- foldM assignOffer ([],[]) pairs
    let (offers, tasks) = unzip ready
    f (map offerID $ offers ++ un) tasks
  where
    tvarA = _arena server
    tvarB = _bullpen server
    assignOffer :: OfferAssignments -> ReadyOffer -> IO OfferAssignments
    assignOffer      (rs, us) (offer, Nothing)   = return (rs, offer:us)
    assignOffer farg@(rs, us) (offer, Just task) = atomically $ runTask offer task farg `orElse` return (rs, offer:us)
    runTask :: Offer -> Task Ready -> OfferAssignments -> STM OfferAssignments
    runTask offer task (rs, us) = do
    	let task' = runTask' offer task
	modifyTVar' tvarB (S.delete task)
	modifyTVar' tvarA (M.insert (taskID $ _tInfo task') task')
	return ((offer,_tInfo task'):rs, us)
    runTask' :: Offer -> Task Ready -> Task Running
    runTask' offer task = task { _tInfo = (_tInfo task) { taskSlaveID = offerSlaveID offer } }


