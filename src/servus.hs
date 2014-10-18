module Main where

import           Control.Applicative
import           Control.Monad.STM
import           Control.Monad.Loops.STM
import           Control.Concurrent
import           Control.Concurrent.STM.TMVar
import           Data.List
import           Debug.Trace

-- | Drive the main scheduler loop. The server continuously will
-- pull out of the set of expired jobs any which are requesting to
-- be scheduled again. The remaining expired jobs are logged out and
-- discarded.
schedulerLoop s = atomLoop $ do
    traceM "entering scheduler loop"
    (pendingJobs, expiredJobs) <- partitionExpiredJobs
    schedulePendingJobs pendingJobs
    traceM "scheduled"
  where
    partitionExpiredJobs = takeTMVar (expiredJobs s) >>= \e -> return $ partition nextReadyJob e
    schedulePendingJobs pendingJobs = do
        r <- takeTMVar (readyJobs s) `orElse` return []
        traceM ("Ready Jobs: " ++ show r)
        traceM ("Pending Jobs: " ++ show pendingJobs)
        putTMVar (readyJobs s) (r ++ pendingJobs)
    nextReadyJob = (== "a")

data Servus = Servus
    { readyJobs   :: TMVar [String]
    , activeJobs  :: TMVar [String]
    , expiredJobs :: TMVar [String]
    }

main = do
    servus <- Servus 
              <$> (newTMVarIO ["a","b","c"])
              <*> newEmptyTMVarIO 
              <*> newEmptyTMVarIO

    forkAtomLoop $ do
        traceM "entering framework loop"
        r <- takeTMVar (readyJobs servus)
        e <- takeTMVar (expiredJobs servus) `orElse` return []
        traceM ("Run Jobs: " ++ show r)
        traceM ("Expired Jobs: " ++ show e)
        putTMVar (expiredJobs servus) (e ++ r)
        traceM "Done"

    schedulerLoop servus
