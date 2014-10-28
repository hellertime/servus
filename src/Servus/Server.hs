{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Servus.Server where

import           Control.Applicative
import           Control.Concurrent.STM
import           Control.Monad.Reader
import qualified Data.Map.Strict as M

import Servus.Config
import Servus.Task

data ServerState = ServerState
    { _conf     :: ServusConf         -- ^ Parsed server configuration
    , _library  :: TVar TaskLibrary   -- ^ Task library is updated via REST API and during config
    , _nursery  :: TChan TaskConf     -- ^ The task nursery holds new task instances which were triggered remotely
    , _bullpen  :: TVar TaskBullpen   -- ^ Task bullpen holds instances awaiting offers from mesos
    , _arena    :: TVar TaskArena     -- ^ Task arean holds launched instances
    , _mortuary :: TChan TaskHistory  -- ^ Task mortuary holds terminal task instances
    }

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
