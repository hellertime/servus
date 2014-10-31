{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Servus.Task where

import qualified Data.ByteString.Char8 as C8
import qualified Data.Map.Strict       as M
import           Data.RangeSpace
import qualified Data.Text 	       as T
import 		 Data.Text.Encoding           (encodeUtf8)
import           Data.Time
import           System.Mesos.Types           (TaskInfo (..))
import qualified System.Mesos.Types    as MT

import           Servus.Config

-- | 'TaskSchedule' is used by the scheduler when selecting a task to run
data TaskSchedule = TaskSchedule
    { _tsTimeBounds :: Maybe (Bounds UTCTime)
    , _tsReadyTime :: UTCTime
    }
  deriving (Show, Eq, Ord)

-- | 'Task', carries the information about a task as it progresses through
-- its lifecycle. The phantom type tracks the state.
data Task a = Task 
    { _tConf  :: TaskConf
    , _tSched :: TaskSchedule
    , _tInfo  :: MT.TaskInfo
    }
  deriving (Show, Eq)

instance Ord (Task a) where
    compare (Task cx sx _) (Task cy sy _) = (compare cx cy) `compare` (compare sx sy)

-- | States of a 'Task'
data Ready
data Running
data Finished

-- | Build and return a new task instance, based on a config and an id
newTask :: TaskConf -> MT.TaskID -> IO (Task Ready)
newTask conf tid = getCurrentTime >>= \t -> return $ Task conf (sched {_tsReadyTime = t}) info
  where
    sched = TaskSchedule Nothing (UTCTime (ModifiedJulianDay 0) (secondsToDiffTime 0))
    info  = MT.TaskInfo { taskInfoName       = encodeUtf8 $ _tcName conf
                        , taskID             = tid
                        , taskSlaveID        = "" -- ^ must populate strict fields
                        , taskResources      = map fromResource (maybe [] _rsrcs $ _tcResources conf)
                        , taskImplementation = MT.TaskCommand cmd
                        , taskData           = Nothing
                        , taskContainer      = Nothing
                        , taskHealthCheck    = Nothing
                        }
    cmd  = MT.CommandInfo [] Nothing (MT.ShellCommand "") Nothing

fromResource :: (T.Text, Resource) -> MT.Resource
fromResource = uncurry go
  where
    go name value = MT.Resource { resourceName = encodeUtf8 name, resourceValue = go' value, resourceRole = Nothing }
    go' (Scalar n)  = MT.Scalar n
    go' (Ranges rs) = MT.Ranges $ map (\(l,h) -> (fromIntegral l, fromIntegral h)) rs
    go' (Set    s)  = MT.Set $ map encodeUtf8 s
    go' (Text   t)  = MT.Text $ encodeUtf8 t

-- | The 'TaskLibrary' is a collection of 'TaskConf' indexed by 'TaskName'
-- On startup the server puts any tasks found in the configuration into
-- the library. During runtime, the library can be manipulated via the
-- REST API (@Servus.Http@).
newtype TaskLibrary = TaskLibrary { fromTaskLibrary :: M.Map TaskName TaskConf }

-- | Create a 'TaskLibrary' by extracting the 'TaskConf' from the 'ServusConf'
newTaskLibrary :: ServusConf -> TaskLibrary
newTaskLibrary = TaskLibrary . M.fromList . map (\t -> (_tcName t, t)) . _scTasks

-- | Find the 'TaskConf' in the 'TaskLibrary' with the passed name
lookupTaskConf :: TaskLibrary -> TaskName -> Maybe TaskConf
lookupTaskConf (TaskLibrary l) n = M.lookup n l

insertLookupTaskConf :: TaskLibrary -> TaskConf -> (Maybe TaskConf, TaskLibrary)
insertLookupTaskConf (TaskLibrary l) c = (c', TaskLibrary l')
  where
    (c', l') = M.insertLookupWithKey (\_ a _ -> a) (_tcName c) c l

{--

-- | A 'Task' contains the configuration of a task, and a mesos 'TaskInfo'
-- when the task has been launched. Users do not obtain a 'Task' directly
-- and instead will always deal with a 'Task' in a given state:
-- * 'ReadyTask'
-- * 'RunningTask'
-- * 'TerminatedTask'
data Task = Task
    { _taskConf :: TaskConf       -- ^ 'TaskConf' defines the task
    , _taskInfo :: Maybe TaskInfo -- ^ 'TaskInfo' is a mesos handle to a running task
    }
  deriving (Show, Eq)

instance Ord Task where
    compare x y = compare (_taskConf x) (_taskConf y)

newtype NewTask        = NewTask Task
newtype ReadyTask      = ReadyTask Task
newtype RunningTask    = RunningTask Task
newtype TerminatedTask = TerminatedTask Task

-- | Construct a 'NewTask' from a 'TaskConf' and 'TaskID'
newTask :: TaskConf -> TaskID -> NewTask
newTask tc tid = Task $ tc (Just $ tinfo { taskID = tid })
  where
    tinfo = TaskInfo {..} -- ^ default all fields to bottom

-- | Internal type which is used to track the progress of a task
data TaskRecord a = TaskRecord
    { _trTimeBounds :: Maybe (Bounds UTCTime) -- ^ lower bound is the launch time, upper is the slack
    , _trTask       :: a
    }
  deriving (Show, Eq, Ord)

newtype TaskNursery = TaskNursery { fromTaskNursery :: TaskRecord NewTask }

-- | Final state of a task instance
newtype TaskHistory = TaskHistory { fromTaskHistory :: TaskRecord TerminatedTask }

-- | The 'TaskBullpen' is a collection of 'Task' which are awaiting offers from mesos.
-- The structure is prioritized by when a task should launch, and based on that priority
-- ordering a best-fit search is done to match an offer to a task.
newtype TaskBullpen = TaskBullpen { fromTaskBullpen :: S.Set (TaskRecord ReadyTask) }

newTaskBullpen = TaskBullpen $ S.empty

-- | Create a task instance which can be sent to the nursery
-- A 'NewTask' has a partially applied 'TaskInfo' which is
-- valid only for 'taskID' and no other field
newTask :: TaskConf -> TaskID -> NewTask
newTask c t = NewTask

-- | Schedule a task into the bullpen. The task will trigger asap.
scheduleTaskNow :: TaskConf -> TaskBullpen -> TaskBullpen
scheduleTaskNow task (TaskBullpen bull) = TaskBullpen $ S.insert (go task) bull
  where
    go task = TaskRecord Nothing $ ReadyTask $ Task task Nothing

-- | Schedule as task into the bullpen. The task will only accept offers while its time
-- bounds are valid. Otherwise it will be evicted and become terminal.
scheduleTask :: TaskConf -> UTCTime -> TaskBullpen -> TaskBullpen
scheduleTask task time (TaskBullpen bull) = TaskBullpen $ S.insert (go task time) bull
  where
    go task time = TaskRecord (Just (time, time)) $ ReadyTask $ Task task Nothing

instance Ord TaskID where
    compare (TaskID x) (TaskID y) = compare x y

-- | The 'TaskArena' is a collection of 'Task' which have obtained offers from mesos, and
-- are now in various phases of launch. Each 'Task' will remain in the arena until it 
-- transitions to a terminal state. At which point it will be history.
newtype TaskArena = TaskArena { fromTaskArena :: M.Map TaskID (TaskRecord RunningTask) }

newTaskArena = TaskArena $ M.empty

-- | Run a 'ReadyTask' by converting it to a 'RunningTask' and associating it with a
-- mesos 'TaskInfo', stored in the 'TaskArena' and indexed by a 'TaskID', which is
-- implicit in the 'TaskInfo'
runTask :: TaskRecord ReadyTask -> TaskInfo -> TaskArena -> TaskArena
runTask record info (TaskArena arena) = TaskArena $ M.insert (taskID info) record' arena
  where
    (ReadyTask ready) = _trTask record
    running = RunningTask $ ready { _taskInfo = Just info }
    record' = record { _trTask = running }

--}
