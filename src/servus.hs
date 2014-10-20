module Main where

import           Control.Applicative
import           Control.Monad
import           Control.Monad.STM
import           Control.Monad.Loops.STM
import           Control.Concurrent
import           Control.Concurrent.STM.TMVar
import           Data.List
import           Data.Map                     as M
import           Data.Monioid ((<>))
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
    readyJobs' =  maybe pendingJobs (++ pendingJobs) readyJobs
    nextReadyJob = (== "a")

data ServusJob = ServusJob
    { _sjName :: String
    }

data Servus = Servus
    { _sReadyJobs   :: TMVar [ServusJob]
    , _sActiveJobs  :: TMVar (M.Map TaskID ServusJob)
    , _sExpiredJobs :: TMVar [ServusJob]
    }

satisfyOffer :: Servus -> Offer -> STM (Maybe ServusJob)
satisfyOffer s _ = case takeTMVar (_sReadyJobs s) of
    []     -> return Nothing
    (j:js) -> putTMVar (_sReadyJobs s) js >> return $ Just j

putActiveJob :: Servus -> ServusJob -> STM ()
putActiveJob s j = do
    activeJobs <- takeTMVar (_sActiveJobs s)
    putTMVar (_sActiveJobs s) (j : activeJobs)

takeActiveJob :: Servus -> TaskID -> STM (Maybe ServusJob)
takeActiveJob s tid = atomically $ case takeTMVar (_sActiveJobs s) of
    [] -> return Nothing
    (

expireJob :: Servus -> TaskID -> STM ServusJob
expireJob s tid = do
    case takeTMVar (_sActiveJobs s) of
        [] -> putTMVar


data ServusScheduler = ServusScheduler
    { _ssServus :: Servus
    }

instance ToScheduler ServusScheduler where
    registered _ _ _ _ = putStrLn "servus: registered"

    resourceOffers s driver offers = do
        forM_ offers $ \offer -> do
            case atomically $ tryTakeTMVar (_sReadyJobs servus) of
                Nothing        -> declineOffer driver (offerID offer) filters
                Just readyJobs -> do
                    readyJob <- atomically $ satisfyOffer servus offer
                    status <- launchTasks
                        driver
                        [ offerID offer ]
                        [ TaskInfo (_sjName readyJob) (TaskID "task") (offerSlaveID offer) requiredResources
                            (TaskExecutor $ executorSettings $ offerFrameworkID offer)
                            Nothing
                            Just $ CommandInfo [] Nothing "ps -ef" Nothing
                            Nothing
                        ]
                        filters
                    atomically $ putActiveJob readyJob
        return ()
      where
        servus = (_ssServus s)

    statusUpdate s driver status = do
        when (taskStatusState status == Finished) $ do
            atomically $ do
                expiredJobs <- takeTMVar (_sExpiredJobs servus)
                activeJobs  <-
                
      where
        servus = (_ssServus s)

main = do
    servus <- Servus 
              <$> (newTMVarIO ["a","b","c"])
              <*> (newTMVarIO M.emptyMap)
              <*> (newTMVarIO [])

    forkAtomLoop $ do
        readyJobs   <- takeTMVar $ _sReadyJobs servus
        expiredJobs <- tryTakeMVar $ _sExpiredJobs servus
        putTMVar (_sExpiredJobs servus) expiredJobs'
      where
        expiredJobs' = maybe readyJobs (++ readyJobs) expiredJobs

    atomLoop $ schedulerLoop servus
