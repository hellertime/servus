{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Control.Applicative
import           Control.Lens
import           Control.Monad
import           Control.Monad.STM
import           Control.Monad.Loops.STM
import           Control.Concurrent
import           Control.Concurrent.STM.TMVar
import qualified Data.ByteString.Char8        as C
import           Data.List
import qualified Data.Map.Strict              as M
import           Data.Maybe (maybe)
import           Data.Monoid ((<>))
import           Data.Tuple (swap)
import           System.Exit
import           System.Mesos.Resources
import           System.Mesos.Scheduler
import           System.Mesos.Types

cpusPerTask :: Double
cpusPerTask = 1

memPerTask :: Double
memPerTask = 32

requiredResources :: [Resource]
requiredResources = [cpusPerTask ^. re cpus, memPerTask ^. re mem]

executorSettings fid cmd = e { executorName = Just "Servus Executor" }
  where
    e = executorInfo (ExecutorID "command") fid (CommandInfo [] Nothing (ShellCommand cmd) Nothing) requiredResources

withTMVar mvar f = do
    v <- takeTMVar mvar
    (v', a) <- f v
    putTMVar mvar v'
    return a

-- | Drive the main scheduler loop. The server continuously will
-- pull out of the set of expired jobs any which are requesting to
-- be scheduled again. The remaining expired jobs are logged out and
-- discarded.
schedulerLoop s = withTMVar (_sExpiredJobs s) $ \expiredJobs -> do
    expiredJobs' <- rescheduleExpiredJobs expiredJobs
    return (expiredJobs', ())
  where
    rescheduleExpiredJobs expiredJobs = 
        let (ps, es) = partition nextReadyJob expiredJobs
        in
            withTMVar (_sReadyJobs s) $ \readyJobs -> return (ps ++ readyJobs, es)
    nextReadyJob = (== "servus-job-1") . _sjName

data ServusJob = ServusJob
    { _sjName :: C.ByteString
    }

data Servus = Servus
    { _sReadyJobs   :: TMVar [ServusJob]
    , _sActiveJobs  :: TMVar (M.Map C.ByteString ServusJob)
    , _sExpiredJobs :: TMVar [ServusJob]
    }

satisfyOffer :: Servus -> Offer -> STM (Maybe ServusJob)
satisfyOffer s _ = withTMVar (_sReadyJobs s) $ \case
    []     -> return ([], Nothing)
    (j:js) -> return (js, Just j)

putActiveJob :: Servus -> TaskID -> ServusJob -> STM ()
putActiveJob s tid j = withTMVar (_sActiveJobs s) $ \activeJobs -> return (M.insert (fromTaskID tid) j activeJobs, ())

takeActiveJob :: Servus -> TaskID -> STM (Maybe ServusJob)
takeActiveJob s tid = withTMVar (_sActiveJobs s) $ 
    \activeJobs -> return $
        if (M.null activeJobs)
            then (M.empty, Nothing)
            else swap $ M.updateLookupWithKey (const2 Nothing) (fromTaskID tid) activeJobs
  where
    const2 c _ _ = c

expireJob :: Servus -> TaskID -> STM ()
expireJob s tid = do
    j <- takeActiveJob s tid
    withTMVar (_sExpiredJobs s) $ 
        \expiredJobs -> return $ (maybe expiredJobs (: expiredJobs) j, ())

data ServusScheduler = ServusScheduler
    { _ssServus :: Servus
    }

instance ToScheduler ServusScheduler where
    registered _ _ _ _ = putStrLn "servus: registered"

    resourceOffers s driver offers = do
        forM_ offers $ \offer -> do
            readyJob <- atomically $ satisfyOffer servus offer
            case readyJob of
                Nothing       -> do
                    putStrLn "servus: offer declined no ready jobs"
                    declineOffer driver (offerID offer) filters
                Just readyJob -> do
                    putStrLn "servus: offer accepted"
                    status <- launchTasks
                        driver
                        [ offerID offer ]
                        [ TaskInfo (_sjName readyJob) (TaskID "task") (offerSlaveID offer) requiredResources
                            (TaskExecutor $ executorSettings (offerFrameworkID offer) "ps -ef")
                            Nothing
                            Nothing
                            Nothing
                        ]
                        (Filters Nothing)
                    putStrLn "servus: launched task"
                    atomically $ putActiveJob servus "task" readyJob
                    putStrLn "servus: marked task as active"
                    return status
        return ()
      where
        servus = (_ssServus s)

    statusUpdate s driver status = do
        putStrLn $ "servus: task " <> show (taskStatusTaskID status) <> " is in state " <> show (taskStatusState status)
        print status
        when (taskStatusState status `elem` [Lost, Finished]) $ atomically $ expireJob servus (taskStatusTaskID status)
                
      where
        servus = (_ssServus s)

    errorMessage _ _ message = C.putStrLn message

main = do
    servus <- Servus 
              <$> (newTMVarIO [ServusJob "servus-job-1"])
              <*> (newTMVarIO M.empty)
              <*> (newTMVarIO [])

    forkAtomLoop $ schedulerLoop servus

    let fi = (frameworkInfo "" "Servus") { frameworkRole = Just "*" }
    status <- withSchedulerDriver (ServusScheduler servus) fi "127.0.0.1:5050" Nothing $ \d -> do
        status <- run d
        stop d False
    if status /= Stopped
        then exitFailure
        else exitSuccess
