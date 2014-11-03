{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Servus.Task where

import           Control.Arrow                  ((***))
import qualified Data.ByteString       as B
import qualified Data.ByteString.Char8 as C8
import           Data.Digest.Human              (humanHash)
import qualified Data.Map.Strict       as M
import           Data.Maybe
import           Data.RangeSpace
import qualified Data.Text 	       as T
import 		 Data.Text.Encoding             (encodeUtf8)
import           Data.Time
import           Data.UUID.V4                   (nextRandom)
import           Data.UUID.V5                   (generateNamed)
import qualified Data.UUID             as UUID
import           System.Mesos.Types             (TaskInfo (..), TaskID (..), ExecutorID (..), ExecutorInfo (..))
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
    { _tConf   :: TaskConf
    , _tSched  :: TaskSchedule
    , _tInfo   :: MT.TaskInfo
    , _tStatus :: Maybe MT.TaskStatus
    }
  deriving (Show, Eq)

instance Ord (Task a) where
    compare (Task cx sx _ _) (Task cy sy _ _) = (compare cx cy) `compare` (compare sx sy)

-- | States of a 'Task'
data Ready
data Running
data Finished

-- | Build and return a new task instance, based on a config and an id
newTask :: TaskConf -> MT.TaskID -> IO (Task Ready)
newTask conf tid = getCurrentTime >>= \t -> return $ Task conf (sched {_tsReadyTime = t}) info Nothing
  where
    sched = TaskSchedule Nothing (UTCTime (ModifiedJulianDay 0) (secondsToDiffTime 0))
    info  = MT.TaskInfo { taskInfoName       = encodeUtf8 $ _tcName conf
                        , taskID             = tid
                        , taskSlaveID        = "" -- ^ must populate strict fields
                        , taskResources      = map fromResource (maybe [] _rsrcs $ _tcResources conf)
                        , taskImplementation = fromCommandConf tid $ _tcCommand conf
                        , taskData           = Nothing
                        , taskContainer      = Nothing
                        , taskHealthCheck    = Nothing
                        }

-- | Run a task, requires a SlaveID and a FrameworkID
runTask :: Task Ready -> MT.FrameworkID -> MT.SlaveID -> Task Running
runTask task fid sid = task'
  where
    task' = task { _tInfo = info' }
    info  = _tInfo task
    info' = info { taskSlaveID        = sid
                 , taskImplementation = taskImplementation'
                 }
    taskImplementation' = case (taskImplementation info) of
                              (MT.TaskExecutor ei) -> MT.TaskExecutor $ ei { executorInfoFrameworkID = fid }
                              ci                   -> ci

-- | Complete a task, and update its final status
finishTask :: Task Running -> MT.TaskStatus -> Task Finished
finishTask task status = task { _tStatus = Just status } 

fromResource :: (T.Text, Resource) -> MT.Resource
fromResource = uncurry go
  where
    go name value = MT.Resource { resourceName = encodeUtf8 name, resourceValue = go' value, resourceRole = Nothing }
    go' (Scalar n)  = MT.Scalar n
    go' (Ranges rs) = MT.Ranges $ map (fromIntegral *** fromIntegral) rs
    go' (Set    s)  = MT.Set    $ map encodeUtf8 s
    go' (Text   t)  = MT.Text   $ encodeUtf8 t

fromCommandConf :: MT.TaskID -> CommandConf -> MT.TaskExecutionInfo
fromCommandConf tid = go
  where
    go cc | isJust $ _ccExecutor cc = MT.TaskExecutor $ toExecutorInfo tid cc
          | otherwise               = MT.TaskCommand  $ toCommandInfo cc

fromVolume :: Volume -> MT.Volume
fromVolume v = let volumeContainerPath = encodeUtf8 $ _volContainerPath v
                   volumeHostPath      = fmap encodeUtf8 $ _volHostPath v
                   volumeMode          = if _volReadOnly v then MT.ReadOnly else MT.ReadWrite
                in MT.Volume {..}

toContainerInfo :: ContainerConf -> MT.ContainerInfo
toContainerInfo (DockerConf image vols) = let containerInfoContainerType = MT.Docker $ encodeUtf8 image
                                              containerInfoVolumes       = map fromVolume $ _vols vols
                                          in MT.ContainerInfo {..}

toExecutorInfo :: MT.TaskID -> CommandConf -> MT.ExecutorInfo
toExecutorInfo tid = go
  where
    go cc = let (Just executorConf)       = _ccExecutor cc
                executorInfoExecutorID    = generateExecutorID executorConf
                executorInfoFrameworkID   = "" -- ^ Will be filled in inside the scheduler loop
                executorInfoCommandInfo   = toCommandInfo cc
                executorInfoContainerInfo = fmap toContainerInfo $ _ccContainer cc
                executorInfoResources     = map fromResource (maybe [] _rsrcs $ _execResources executorConf)
                executorName              = Just $ encodeUtf8 $ _execName executorConf
                executorSource            = Just $ MT.fromTaskID tid
                executorData              = Nothing
            in MT.ExecutorInfo {..}

fromEnvVar :: (T.Text, T.Text) -> (C8.ByteString, C8.ByteString)
fromEnvVar = encodeUtf8 *** encodeUtf8

fromUri :: Uri -> MT.CommandURI
fromUri (Uri val exec ext) = MT.CommandURI (encodeUtf8 val) exec ext

toCommandValue :: CommandSpec -> MT.CommandValue
toCommandValue (ShellCommand cmd)      = MT.ShellCommand $ encodeUtf8 cmd
toCommandValue (ExecCommand arg0 argv) = MT.RawCommand (encodeUtf8 arg0) $ map encodeUtf8 argv

toCommandInfo :: CommandConf -> MT.CommandInfo
toCommandInfo cc = let commandInfoURIs    = map fromUri (maybe [] _uris $ _ccUris cc)
                       commandEnvironment = fmap (map fromEnvVar . _evs) $ _ccEnv cc
                       commandValue       = toCommandValue $ _ccRun cc
                       commandUser        = fmap encodeUtf8 $ _ccUser cc
                    in MT.CommandInfo {..}

-- | Generate a TaskID using a human hash of a random UUID
randomTaskID :: TaskConf -> IO TaskID
randomTaskID tc = nextRandom >>= return . TaskID . textEncode . taskIdGen
  where
    textEncode = encodeUtf8 . T.append (flip T.snoc '.' $ _tcName tc) . T.intercalate "_"
    taskIdGen = humanHash 5 . UUID.toString

-- | Generate a ExecutorID deterministcally
generateExecutorID :: ExecutorConf -> ExecutorID
generateExecutorID cc = ExecutorID $ textEncode $ executorIdGen $ executorUuid
  where
    (Just executorUuidNamespace) = UUID.fromString "e2b82c48-fb4b-40e8-bff7-8daf0424b0d9"
    textEncode = encodeUtf8 . T.append (flip T.snoc '.' $ _execName cc) . T.intercalate "_"
    executorIdGen = humanHash 5 . UUID.toString
    executorUuid = generateNamed executorUuidNamespace $ nameEncode cc
    nameEncode = B.unpack . encodeUtf8 . _execName

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
