{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Servus.Server where

import           Control.Arrow                 ((&&&))
import           Control.Applicative
import           Control.Concurrent.STM
import           Control.Monad
import           Control.Monad.Reader
import 		 Data.List                     (sortBy, groupBy, genericLength)
import qualified Data.Map.Strict         as M
import           Data.Maybe                    (listToMaybe)
import qualified Data.Set                as S
import           Data.Text                     (Text)
import qualified Data.Text               as T
import           Data.Text.Encoding            (encodeUtf8)   
import           Data.Time.Clock               (diffUTCTime)
import qualified System.Mesos.Scheduler  as MZ
import qualified System.Mesos.Types      as MZ

import           Servus.Config
import           Servus.Task             hiding (finishTask)
import qualified Servus.Task             as ST

data ServerState = ServerState
    { _log      :: LoggerSet                             -- ^ Log handle
    , _conf     :: ServusConf                            -- ^ Parsed server configuration
    , _driver   :: TMVar MZ.SchedulerDriver              -- ^ Handle to the mesos driver used for async message sends
    , _library  :: TVar TaskLibrary                      -- ^ Task library is updated via REST API and during config
    , _nursery  :: TChan (TaskConf)                      -- ^ Task nursery holds task confs awaiting the bullpen
    , _bullpen  :: TVar (M.Map MZ.TaskID (Task Ready))   -- ^ Task bullpen holds instances awaiting offers from mesos
    , _arena    :: TVar (M.Map MZ.TaskID (Task Running)) -- ^ Task arean holds launched instances
    , _mortuary :: TChan (Task Finished)                 -- ^ Task mortuary holds terminal task instances
    }

instance Ord MZ.TaskID where
    (MZ.TaskID a) `compare` (MZ.TaskID b) = a `compare` b

instance Ord MZ.SlaveID where
    (MZ.SlaveID a) `compare` (MZ.SlaveID b) = a `compare` b

newServerState :: ServusConf -> IO ServerState
newServerState _log _conf = do
    _driver   <- newEmptyTMVarIO
    _library  <- newTVarIO $ newTaskLibrary _conf
    _nursery  <- newTChanIO
    _bullpen  <- newTVarIO M.empty
    _arena    <- newTVarIO M.empty
    _mortuary <- newTChanIO
    return ServerState {..}

newtype TaskM a = TaskM { runTaskM :: ReaderT ServerState IO a }
  deriving (Applicative, Functor, Monad, MonadIO, MonadReader ServerState)

taskM :: MonadTrans t => TaskM a -> t TaskM a
taskM = lift

toTaskList :: M.Map MZ.TaskID (Task a) -> [Task a]
toTaskList = S.toAscList . S.fromList . M.elems

-- | Obtain the list of tasks presently in the arena
-- Note the conversion through Set, so we sort by Task not Task ID
getArenaTasks :: ServerState -> IO [Task Running]
getArenaTasks = fmap toTaskList . readTVarIO . _arena

-- | Obtain the list of tasks presently in the bullpen
getBullpenTasks :: ServerState -> IO [Task Ready]
getBullpenTasks = fmap toTaskList . readTVarIO . _bullpen

-- | Obtain the task from either the arena or the bullpen
getTask :: MZ.TaskID -> ServerState -> IO (Maybe (Either (Task Running) (Task Ready)))
getTask tid server = do
    aTask <- arenaTask
    bTask <- bullpenTask
    return $ Left `fmap` aTask <|> Right `fmap` bTask
  where
    arenaTask :: IO (Maybe (Task Running))
    arenaTask = getArenaTask tid server
    bullpenTask :: IO (Maybe (Task Ready))
    bullpenTask = getBullpenTask tid server

-- | Obtain the task by taskId, from arena
getArenaTask :: MZ.TaskID -> ServerState -> IO (Maybe (Task Running))
getArenaTask tid = fmap (M.lookup tid) . readTVarIO . _arena

-- | Obtain the task by taskId, from bullpen
getBullpenTask :: MZ.TaskID -> ServerState -> IO  (Maybe (Task Ready))
getBullpenTask tid = fmap (M.lookup tid) . readTVarIO . _bullpen

-- | Obtain the 'TaskLibrary' from the 'ServerState'
getTaskLibrary :: ServerState -> IO TaskLibrary
getTaskLibrary = readTVarIO . _library

-- | Get a 'TaskConf' from the 'TaskLibrary' if it exists, otherwise 'Nothing'
getTaskConf :: TaskName -> ServerState -> IO (Maybe TaskConf)
getTaskConf name = fmap (flip lookupTaskConf name) . getTaskLibrary

-- | Put a 'TaskConf' into the 'TaskLibrary' if a previous version exists
-- it will be returned by the function
putTaskConf :: TaskConf -> ServerState -> IO (Maybe TaskConf)
putTaskConf conf server = atomically $ do
    library <- readTVar tvarL
    let (conf', library') = insertLookupTaskConf library conf
    writeTVar tvarL library'
    return conf'
  where
    tvarL = _library server

-- | Encode if a task can be run
data RunStatus = DelayLaunch Double -- ^ Can't run, launch delay
               | ZeroFreeInsts      -- ^ Can't run, no slots
               | FreeInsts Integer  -- ^ Ok, return count of free slots:w

-- | Determine if a Task can run based on its schedule and trigger
-- and inspecting a list of tasks that are already running or ready
-- The result will either be the number of unused instances remaning
-- or the remaining balance of time left between launch cycles
_taskRunStatus :: Task Ready -> [Task a] -> RunStatus
_taskRunStatus task = uncurry canRun . remainders . dropWhile ((/= taskName task) . taskName)
  where
    readyTimeDelta   = realToFrac . (flip diffUTCTime $ taskReadyTime task) . taskReadyTime
    recentLaunches   = takeWhile (< taskLaunchRate task) . map readyTimeDelta
    remainders       = (((taskInstMax task -) . genericLength) &&& (listToMaybe . recentLaunches))
    canRun 0 Nothing = ZeroFreeInsts
    canRun n Nothing = FreeInsts n
    canRun _ (Just t)= DelayLaunch t
    taskName         = _tcName . _tConf
    taskReadyTime    = _tsReadyTime . _tSched
    taskLaunchRate   = _tcLaunchRate . _tcTrigger . _tConf
    taskInstMax      = _tcMaxInstances . _tcTrigger . _tConf

-- | Put a 'TaskConf' into the bullpen to await offers
-- If the current environment cannot accept the task an
-- error will be reported Left, otherwise the taskId of the 
-- accepted task will be returned Right
runTaskConf :: TaskConf -> ServerState -> IO (Either RunStatus MZ.TaskID)
runTaskConf conf server = do
    tid  <- randomTaskID conf
    task <- newTask conf tid
    atomically $ do
        arena   <- readTVar tvarA >>= return . toTaskList
        bullpen <- readTVar tvarB >>= return . toTaskList
        let readyTasks     = map fromReadyTask bullpen
            runningTasks   = map fromRunningTask arena
        case _taskRunStatus task (readyTasks ++ runningTasks) of
            FreeInsts _ -> modifyTVar' tvarB (M.insert tid task) >> return (Right tid)
            runStat     -> return $ Left runStat
  where
    tvarA          = _arena server
    tvarB          = _bullpen server

-- | Find the first match in the bullpen for the given offers
-- returns a list of lists, where each sub-list is a list of
-- offer task pairs, where all offers are for the same slave
matchOffers :: [MZ.Offer] -> ServerState -> IO [[ReadyOffer]]
matchOffers offers server = do
    let tvar = _bullpen server
    bullpen <- readTVarIO tvar
    -- TODO: Really implement matching
    return $ groupBy eqSlaveId $ sortBy ordSlaveId $ zip offers $ (map Just $ toTaskList bullpen) ++ (repeat Nothing) -- ^ offers paired with Nothing are discarded
  where
    getSlaveId     = MZ.offerSlaveID . fst
    ordSlaveId x y = getSlaveId x `compare` getSlaveId y
    eqSlaveId x y  = getSlaveId x == getSlaveId y

-- | Aliaases to make runTasks types easier
type ReadyOffer       = (MZ.Offer, Maybe (Task Ready))
type RunningOffer     = (MZ.Offer, MZ.TaskInfo)
type OfferAssignments = ([RunningOffer], [MZ.Offer])

-- | Run tasks which have been given offers.
-- Tasks are removed from the bullpen and put into the arena
runTasks :: [ReadyOffer] -> ServerState -> ([MZ.OfferID] -> [MZ.TaskInfo] -> IO MZ.Status) -> IO MZ.Status
runTasks pairs server f = do
    (ready, un) <- foldM assignOffer oa pairs
    let (offers, tasks) = unzip ready
    f (map MZ.offerID $ offers ++ un) tasks
  where
    oa    = ([],[])
    tvarA = _arena server
    tvarB = _bullpen server
    assignOffer :: OfferAssignments -> ReadyOffer -> IO OfferAssignments
    assignOffer oa = \case
                      (offer, Nothing)   -> return $ fmap (offer:) oa
                      (offer, Just task) -> atomically $ go offer task oa `orElse` (return $ fmap (offer:) oa)
    go :: MZ.Offer -> Task Ready -> OfferAssignments -> STM OfferAssignments
    go offer task (rs, us) = do
        let task' = runTask task (MZ.offerFrameworkID offer) (MZ.offerSlaveID offer)
        let tid   = MZ.taskID $ _tInfo task'
	modifyTVar' tvarB $ M.delete tid
	modifyTVar' tvarA $ M.insert tid task'
	return ((offer,_tInfo task'):rs, us)

-- | Remove a task from the arena, and update its task status
finishTask :: MZ.TaskStatus -> ServerState -> IO ()
finishTask status server = atomically $ do
    task <- readTVar tvarA >>= \arena -> let (task, arena') = remove tid arena 
                                        in writeTVar tvarA arena' >> return task
    case task of
        Nothing -> return ()
        Just t  -> writeTChan tchanM (t { _tStatus = Just status })
  where
    tvarA  = _arena server
    tchanM = _mortuary server
    tid    = MZ.taskStatusTaskID status
    remove = M.updateLookupWithKey (\_ _ -> Nothing)

-- | Send a 'killTask' to a given taskID
killTask :: MZ.TaskID -> ServerState -> IO MZ.Status
killTask tid server = (atomically $ readTMVar $ _driver server) >>= flip MZ.killTask tid

-- | The nursery loop waits on the _nursery TChan
-- and runs the task configurations which arrive on it
-- For a given task conf it will continue to run the conf
-- until it either hits a launch delay, in which case it will
-- write the conf back to the chan, or it will discard the conf
-- if the slots are exhausted
nurseryLoop :: ServerState -> IO ()
nurseryLoop server = forever $ (atomically $ readTChan tchanN) >>= runInstances >>= putBackMaybe
  where
    log = const $ return ()
    tchanN = _nursery server
    runInstances conf = runTaskConf conf server >>= \case
        Right tid            -> log tid >> runInstances conf
        Left ZeroFreeInsts   -> return Nothing
        Left (DelayLaunch n) -> return (Just conf)
    putBackMaybe Nothing     = return ()
    putBackMaybe (Just conf) = atomically $ writeTChan tchanN conf

-- | The mortician loop waits on the _mortuary TChan
-- and will either send tasks off to the garbage collector
-- or it will put them back in the bullpen if they should
-- be restarted
morticianLoop :: ServerState -> IO ()
morticianLoop server = forever $ (atomically $ readTChan tchanM) >>= relaunch >>= log
  where
    log = const $ return () -- TODO: Logging
    tchanM = _mortuary server
    tchanN = _nursery server
    relaunch task = let name    = _tcName    $ _tConf task
                        trigger = _tcTrigger $ _tConf task
                    in if _tcRelaunchOnExit trigger
                            then getTaskConf name server >>= maybe (return noTask) reRun
                            else return noRequest
    noTask = Left $ T.pack "task not in library. cannot relaunch"
    noRequest = Left $ T.pack "no relauch requested"
    reRun conf = (atomically $ writeTChan tchanN conf) >> (return $ Right $ T.pack "relaunched")
