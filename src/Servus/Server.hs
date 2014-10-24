{-# LANGUAGE GeneralizedNewTypeDeriving #-}

module Servus.Server where

import Control.Concurrent.STM
import Control.Monad.Reader

import Servus.Task

data ServerState = ServerState
    { _library  :: TVar TaskLibrary   -- ^ Task library is updated via REST API and during config
    , _nursery  :: TChan SleepingTask -- ^ The task nursery holds new task instances which were triggered remotely
    , _bullpen  :: TVar TaskBullpen   -- ^ Task bullpen holds instances awaiting offers from mesos
    , _arena    :: TVar TaskArena     -- ^ Task arean holds launched instances
    , _mortuary :: TChan TerminalTask -- ^ Task mortuary holds terminal task instances
    }

newtype TaskM a = TaskM { runTaskM :: ReaderT ServerState IO a }
  deriving (Monad, MonadIO, MonadReader ServerState)

taskM :: MonadTrans t => TaskM a -> t TaskM a
taskM = lift
