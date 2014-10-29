{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecordWildCards #-}

module Servus.Server where

import           Control.Applicative
import           Control.Concurrent.STM
import           Control.Monad.Reader
import qualified Data.Map.Strict         as M
import qualified Data.Set                as S
import           Data.Text                    (Text)
import           System.Mesos.Types

import           Servus.Config
import           Servus.Task

data ServerState = ServerState
    { _conf     :: ServusConf                         -- ^ Parsed server configuration
    , _library  :: TVar TaskLibrary                   -- ^ Task library is updated via REST API and during config
    , _nursery  :: TChan (Task Warmup)                -- ^ The task nursery holds new task instances which were triggered remotely
    , _bullpen  :: TVar (S.Set (Task Ready))          -- ^ Task bullpen holds instances awaiting offers from mesos
    , _arena    :: TVar (M.Map TaskID (Task Running)) -- ^ Task arean holds launched instances
    , _mortuary :: TChan (Task Finished)              -- ^ Task mortuary holds terminal task instances
    }

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

-- | Obtain the 'TaskLibrary' from the 'ServerState'
getTaskLibrary :: ServerState -> IO TaskLibrary
getTaskLibrary = atomically . readTVar . _library

-- | Get a 'TaskConf' from the 'TaskLibrary' if it exists, otherwise 'Nothing'
getTaskConf :: TaskName -> ServerState -> IO (Maybe TaskConf)
getTaskConf n s = do
    library <- getTaskLibrary s
    return $ go library n
  where
    go (TaskLibrary lib) name = M.lookup name lib

-- | Put a 'TaskConf' into the 'TaskLibrary' if a previous version exists
-- it will be returned by the function
putTaskConf :: TaskConf -> ServerState -> IO (Maybe TaskConf)
putTaskConf t s = atomically $ do
    library <- readTVar $ _library s
    let (old, library') = insertLookup (_tcName t) t library
    writeTVar (_library s) (TaskLibrary library')
    return old
      where
        insertLookup name conf (TaskLibrary lib) = M.insertLookupWithKey (\_ a _ -> a) name conf lib

-- | Put a 'TaskConf' into the nursery to await offers
-- runTaskConf :: TaskConf -> ServerState -> IO (Either Text TaskID)
