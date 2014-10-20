module Main where

import           Control.Applicative
import           Control.Monad
import           Control.Monad.STM
import           Control.Monad.Loops.STM
import           Control.Concurrent
import           Control.Concurrent.STM.TMVar
import           Data.List
import           Data.Monoid ((<>))
import           Debug.Trace
import           System.Mesos.Scheduler

-- | Drive the main scheduler loop. The server continuously will
-- pull out of the set of expired jobs any which are requesting to
-- be scheduled again. The remaining expired jobs are logged out and
-- discarded.
schedulerLoop s = do
    expiredJobs <- tryTakeTMVar (_sExpiredJobs s)
    readyJobs   <- tryTakeTMVar (_sReadyJobs s)
    putTMVar (_sReadyJobs) readyJobs'
  where
    (pendingJobs, expiredJobs') = maybe ([],[]) (partition nextReadyJob) expiredJobs
    readyJobs' =  maybe pendingJobs (<> pendingJobs) readyJobs
    nextReadyJob = (== "a")

data Servus = Servus
    { _sReadyJobs   :: TMVar [String]
    , _sActiveJobs  :: TMVar [String]
    , _sExpiredJobs :: TMVar [String]
    }

data ServusScheduler = ServusScheduler
    { _ssServus :: Servus
    }

instance ToScheduler ServusScheduler where
    registered _ _ _ _ = putStrLn "servus: registered"

    resourceOffers s driver offers = do
        forM_ offers $ \offer -> atomically $ do
            case tryTakeTMVar (_sReadyJobs servus) of
                Nothing        -> declineOffer driver (offerID offer) filters
                Just readyJobs -> do
                    status <- launchTasks
                        driver
                        [ offerID offer ]
                        [ TaskInfo "Tasker" (TaskID "task") (offerSlaveID offer) requiredResources
                            (TaskExecutor $ executorSettings $ offerFrameworkID offer)
                            Nothing
                            Just $ CommandInfo [] Nothing "ps -ef" Nothing
                            Nothing
                        ]
                        filters
      where
        servus = (_ssServus s)

main = do
    servus <- Servus 
              <$> (newTMVarIO ["a","b","c"])
              <*> newEmptyTMVarIO 
              <*> newEmptyTMVarIO

    forkAtomLoop $ do
        readyJobs   <- takeTMVar $ _sReadyJobs servus
        expiredJobs <- tryTakeMVar $ _sExpiredJobs servus
        putTMVar (_sExpiredJobs servus) expiredJobs'
      where
        expiredJobs' = maybe readyJobs (<> readyJobs) expiredJobs

    atomLoop $ schedulerLoop servus
