module Servus.Task where

import qualified Data.Map.Strict    as M
import           Data.RangeSpace
import qualified Data.Set           as S
import           Data.Time
import           System.Mesos.Types

import Servus.Config

-- | The 'TaskLibrary' is a collection of 'TaskConf' indexed by 'TaskKey'.
-- On startup the server puts any tasks found in the configuration into
-- the library. During runtime, the library can be manipulated via the
-- REST API (@Servus.Http@).
newtype TaskLibrary = TaskLibrary { fromTaskLibrary :: M.Map TaskKey TaskConf }

-- | A 'TaskKey' identifies a 'TaskConf' in a 'TaskLibrary'
-- One creates a 'TaskKey' with a call to 'taskKey'
type TaskKey = (TaskName, TaskOwner)

-- | Generate the 'TaskKey' for the given 'TaskConf'
taskKey :: TaskConf -> TaskKey
taskKey t = (name, owner)
  where
    name  = _tcName t
    owner = _tcOwner t

-- | Create a 'TaskLibrary' by extracting the 'TaskConf' from the 'ServusConf'
newTaskLibrary :: ServusConf -> TaskLibrary
newTaskLibrary = TaskLibrary . M.fromList . map (\t -> (taskKey t, t)) . _scTasks

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

newtype ReadyTask = ReadyTask { fromReadyTask :: Task }
  deriving (Show, Eq, Ord)
newtype RunningTask  = RunningTask  { fromRunningTask :: Task }
  deriving (Show, Eq, Ord)
newtype TerminatedTask = TerminatedTask { fromTerminatedTask :: Task }
  deriving (Show, Eq, Ord)

-- | Internal type which is used to track the progress of a task
data TaskRecord a = TaskRecord
    { _trTimeBounds :: Maybe (Bounds UTCTime) -- ^ lower bound is the launch time, upper is the slack
    , _trTask       :: a
    }
  deriving (Show, Eq, Ord)

-- | Final state of a task instance
newtype TaskHistory = TaskHistory { fromTaskHistory :: TaskRecord TerminatedTask }

-- | The 'TaskBullpen' is a collection of 'Task' which are awaiting offers from mesos.
-- The structure is prioritized by when a task should launch, and based on that priority
-- ordering a best-fit search is done to match an offer to a task.
newtype TaskBullpen = TaskBullpen { fromTaskBullpen :: S.Set (TaskRecord ReadyTask) }

newTaskBullpen = TaskBullpen $ S.empty

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