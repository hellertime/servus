module Main where

import           Control.Applicative
import           Control.Monad.STM
import           Control.Monad.Loops.STM
import           Control.Concurrent.STM.TMVar
import           Data.List
import           Debug.Trace

-- | Drive the main scheduler loop. The server continuously will
-- pull out of the set of expired jobs any which are requesting to
-- be scheduled again. The remaining expired jobs are logged out and
-- discarded.
schedulerLoop s = waitForTrue $ do
    (pendingJobs, expiredJobs) <- partitionExpiredJobs
    traceShow pendingJobs $ return ()
    traceShow expiredJobs $ return ()
    schedulePendingJobs pendingJobs
    isEmptyTMVar (readyJobs s)
  where
    partitionExpiredJobs = takeTMVar (expiredJobs s) >>= \e -> return $ partition nextReadyJob e
    schedulePendingJobs pendingJobs = do
        r <- takeTMVar (readyJobs s) `orElse` return []
        putTMVar (readyJobs s) (r ++ pendingJobs)
    nextReadyJob = (== "a")

data Servus = Servus
    { readyJobs   :: TMVar [String]
    , activeJobs  :: TMVar [String]
    , expiredJobs :: TMVar [String]
    }

main = do
    servus <- Servus <$> newEmptyTMVarIO <*> newEmptyTMVarIO <*> (newTMVarIO ["a","b"])
    atomically $ schedulerLoop servus
