{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Main where

import           Control.Applicative
import           Control.Lens
import           Control.Monad
import           Control.Monad.Reader
import           Control.Monad.STM
-- import           Control.Monad.Loops.STM
import           Control.Concurrent
import qualified Data.ByteString.Char8        as C
import           Data.List
import qualified Data.Map.Strict              as M
import           Data.Maybe (maybe)
import           Data.Monoid ((<>))
import           Data.Tuple (swap)
import           Debug.Trace
import           Options.Applicative
import           System.Exit
import qualified System.IO.Unsafe             as IOU

import           Servus.Config
import           Servus.Http
import           Servus.Mesos
import           Servus.Options
import           Servus.Server
import           Servus.Task

type Threads = MVar [MVar ()]

_threads :: Threads
_threads = IOU.unsafePerformIO $ newMVar []

main :: IO ()
main = execParser opts >>= _main
  where
    opts = info (helper <*> globalOptsParser) desc
    desc = fullDesc <> progDesc "d1" <> header "h1"
    def exc = do
        print exc
        return defaultServusConf
    _main (GlobalOpts c) = do
        _conf  <- either def return =<< parseServusConf c
        _state <- newServerState _conf

        forkThread _threads $ morticianLoop _state
        forkThread _threads $ mesosFrameworkLoop _state
        forkThread _threads $ restApiLoop _state

        waitFor _threads

waitFor :: Threads -> IO ()
waitFor threads = do
    ts <- takeMVar threads
    case ts of
        []     -> return ()
        (m:ms) -> do
            putMVar threads ms
            takeMVar m
            waitFor threads

forkThread :: Threads -> IO () -> IO ThreadId
forkThread threads io = do
    t  <- newEmptyMVar
    ts <- takeMVar threads
    putMVar threads (t:ts)
    forkFinally io (\_ -> putMVar t ())

    {--

-- | Create a skeleton task with some fields populated
mkTaskInfo name = TaskInfo
    { taskInfoName       = name
    , taskID             = C.null
    , taskSlaveID        = C.null
    , taskResources      = []
    , taskImplementation = TaskCommand $ CommandInfo [] Nothing (RawCommand "/bin/true") Nothing
    , taskData           = Nothing
    , taskContainer      = Nothing
    , taskHealthCheck    = Nothing
    }

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
schedulerLoop s = do
    pending <- withTMVar (_sExpiredJobs s) $ return . swap . partition nextReadyJob
    withTMVar (_sReadyJobs s) $ return . swap . ((,) ()) . (++ pending)
  where
    nextReadyJob = (== "servus-job-1") . _sjName

-- | Job configuration.
data JobOptions = JobOptions
    { _joDisplayName :: C.ByteString -- ^ Mesos display name
    , _joConstraints :: Set Resource -- ^ Job resource requirements
    , _joTrigger     :: JobTrigger   -- ^ Trigger job to schedule
    }
  deriving (Show)

-- | A ScheduledJob is one on the ready queue, but not yet matched by 
-- offers from a slave.
newtype ScheduledJob = ScheduledJob { fromScheduledJob :: JobOptions }

data Servus = Servus
    { _sReadyJobs   :: TMVar ![ServusJob]
    , _sActiveJobs  :: TMVar (M.Map C.ByteString ServusJob)
    , _sExpiredJobs :: TMVar ![ServusJob]
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
        putStrLn "servus: accepting resource offers"
        forM_ offers $ \offer -> do
            putStrLn "servus: satisfying resource offer"
            print offer
            readyJob <- atomically $ satisfyOffer servus offer
            print readyJob
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
--                            (TaskExecutor $ executorSettings (offerFrameworkID offer) "/Users/cheller/src/akamai/mesos/build/src/mesos-execute --master=127.0.0.1:5050 --command='/bin/ps -ef' --name=foo")
                            (TaskCommand $ CommandInfo [] Nothing (ShellCommand "ps -ef") Nothing)
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
        when (taskStatusState status `elem` [Lost, Finished]) $ do
            putStrLn "servus: expiring task"
            atomically $ expireJob servus (taskStatusTaskID status)
            putStrLn "servus: done"
                
      where
        servus = (_ssServus s)

    errorMessage _ _ message = C.putStrLn message

    --}

{--
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
--}
