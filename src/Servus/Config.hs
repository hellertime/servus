{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Servus.Config where

import           Control.Applicative
import           Control.Monad               (sequence)
import           Data.Aeson                  (fromJSON)
import           Data.Either                 (either)
import qualified Data.HashMap.Lazy    as HML (lookup, toList, keys, elems, member)
import           Data.Maybe                  (listToMaybe, fromMaybe)
import qualified Data.Text            as T   (Text)
import           Data.Vector                 (Vector)
import qualified Data.Vector          as V   (toList, head, tail)
import           Data.Yaml
import qualified System.Mesos.Types   as M

parseServusConf :: FilePath -> IO (Either ParseException ServusConf)
parseServusConf = decodeFileEither

data ServusConf = ServusConf
    { _scGlobal :: GlobalConf
    , _scHttp   :: HttpConf
    , _scMesos  :: MesosConf
    , _scTasks  :: [TaskConf]
    }
  deriving (Show, Eq, Ord)

defaultServusConf = ServusConf {..}
  where
    _scGlobal = defaultGlobalConf
    _scHttp   = defaultHttpConf
    _scMesos  = defaultMesosConf
    _scTasks  = []

data GlobalConf = GlobalConf
    { _gcCluster :: Bool
    }
  deriving (Show, Eq, Ord)

defaultGlobalConf = GlobalConf {..}
  where
    _gcCluster = False

type Port = Int

data HttpConf = HttpConf
    { _hcPort :: Port
    }
  deriving (Show, Eq, Ord)

defaultHttpConf = HttpConf {..}
  where
    _hcPort = 8080

data MesosConf = MesosConf
    { _mcMaster          :: T.Text
    , _mcName            :: T.Text
    , _mcUser            :: T.Text
    , _mcFailoverTimeout :: Maybe Double
    , _mcCheckpoint      :: Maybe Bool
    , _mcRole            :: Maybe String
    , _mcHostname        :: Maybe String
    , _mcPrincipal       :: Maybe T.Text
    }
  deriving (Show, Eq, Ord)

defaultMesosConf = MesosConf {..}
  where
    _mcMaster          = "127.0.0.1:5050"
    _mcName            = "servus"
    _mcUser            = ""
    _mcFailoverTimeout = Nothing
    _mcCheckpoint      = Nothing
    _mcRole            = Nothing
    _mcHostname        = Nothing
    _mcPrincipal       = Nothing

data Resource = Scalar Double
              | Ranges [(Integer, Integer)]
              | Set [T.Text]
              | Text T.Text
              deriving (Show, Eq, Ord)

data ResourceList = ResourceList
    { _rsrcs :: [(T.Text, Resource)]
    }
  deriving (Show, Eq, Ord)

data EnvVars = EnvVars
    { _evs :: [(T.Text, T.Text)]
    }
  deriving (Show, Eq, Ord)

data URI = URI
    { _uriValue   :: T.Text
    , _uriSetExec :: Maybe Bool
    , _uriExtract :: Maybe Bool
    }
  deriving (Show, Eq, Ord)

data URIList = URIList [URI]
  deriving (Show, Eq, Ord)

data ExecutorConf = ExecutorConf
    { _execName      :: T.Text
    , _execResources :: Maybe ResourceList
    }
  deriving (Show, Eq, Ord)

data Volume = Volume
    { _volHostPath      :: Maybe T.Text
    , _volContainerPath :: T.Text
    , _volReadOnly      :: Bool
    }
  deriving (Show, Eq, Ord)

data VolumeList = VolumeList [Volume]
  deriving (Show, Eq, Ord)

data ContainerConf = DockerConf
    { _dockerImage   :: T.Text
    , _dockerVolumes :: VolumeList
    }
  deriving (Show, Eq, Ord)

data CommandSpec = ShellCommand T.Text
                 | ExecCommand T.Text [T.Text]
                 deriving (Show, Eq, Ord)

data CommandConf = CommandConf
    { _ccRun       :: CommandSpec
    , _ccURIs      :: Maybe URIList
    , _ccEnv       :: Maybe EnvVars
    , _ccUser      :: Maybe T.Text
    , _ccExecutor  :: Maybe ExecutorConf
    , _ccContainer :: Maybe ContainerConf
    }
  deriving (Show, Eq, Ord)

data TriggerConf = TriggerConf
    { _tcRemote       :: Bool
    , _tcMaxInstances :: Integer
    , _tcLaunchRate   :: Double
    , _tcScheduleExpr :: Maybe String
    }
  deriving (Show, Eq, Ord)

defaultTrigger = TriggerConf True 1 1.0 Nothing

type TaskName = T.Text
data TaskOwner = SystemTask | UserTask T.Text
  deriving (Show, Eq, Ord)

data TaskConf = TaskConf
    { _tcName          :: TaskName
    , _tcOwner         :: TaskOwner
    , _tcCommand       :: CommandConf
    , _tcTrigger       :: TriggerConf
    , _tcResources     :: Maybe ResourceList
    }
  deriving (Show, Eq, Ord)

instance FromJSON ServusConf where
    parseJSON (Object o) = do
        _scGlobal <- o .:? "global" .!= defaultGlobalConf
        _scMesos  <- o .:? "mesos"  .!= defaultMesosConf
        _scHttp   <- o .:? "http"   .!= defaultHttpConf
        _scTasks  <- o .:  "tasks"
        return ServusConf {..}

instance FromJSON GlobalConf where
    parseJSON (Object o) = GlobalConf <$> o .:? "cluster" .!= False

instance FromJSON HttpConf where
    parseJSON (Object o) = HttpConf <$> o .:? "port" .!= 8080

instance FromJSON MesosConf where
    parseJSON (Object o) = do
        _mcMaster          <- o .:? "master" .!= "127.0.0.1:5050"
        _mcUser            <- o .:? "user" .!= ""
        _mcFailoverTimeout <- o .:? "failoverTimeout"
        _mcCheckpoint      <- o .:? "checkpoint"
        _mcRole            <- o .:? "role"
        _mcHostname        <- o .:? "hostname"
        _mcPrincipal       <- o .:? "principal"
        return MesosConf { _mcName = "servus"
                         , .. }

instance FromJSON TriggerConf where
    parseJSON (Object o) = do
        _tcRemote       <- o .:? "remote" .!= (if HML.member "schedule" o then False else True)
        _tcMaxInstances <- o .:? "maxInstances" .!= 1
        _tcLaunchRate   <- o .:? "launchRate" .!= 1.0
        _tcScheduleExpr <- o .:? "schedule"
        return TriggerConf {..}

instance FromJSON TaskOwner where
    parseJSON (String s) = return $ UserTask s

instance FromJSON TaskConf where
    parseJSON (Object o) = do
        _tcName      <- o .: "name"
        maybeOwner   <- o .:? "owner"
        _tcCommand   <- o .: "command"
        _tcResources <- o .:? "resources"
        maybeTrigger <- o .:? "trigger"
        return TaskConf { _tcTrigger = fromMaybe defaultTrigger maybeTrigger
                        , _tcOwner   = fromMaybe SystemTask maybeOwner
                        , ..}

instance FromJSON ExecutorConf where
    parseJSON (Object o) = do
        _execName      <- o .: "name"
        _execResources <- o .:? "resources"
        return ExecutorConf {..}

instance FromJSON Resource where
    parseJSON n@(Number _) = Scalar <$> parseJSON n
    parseJSON s@(String _) = Text <$> parseJSON s
    parseJSON (Array a)    = parseArray $ V.toList a
      where
        parseArray a@(x:_) = case x of
            (Number _) -> Set <$> mapM parseJSON a
            (Array _)  -> Ranges <$> mapM parseJSON a
            

instance FromJSON ResourceList where
    parseJSON (Object o) = do 
        k <- return $ HML.keys o
        v <- mapM parseJSON $ HML.elems o
        return $ ResourceList (zip k v)

instance FromJSON EnvVars where
    parseJSON (Object o) = do
        k <- return $ HML.keys o
        v <- mapM parseJSON $ HML.elems o
        return $ EnvVars (zip k v)

instance FromJSON URI where
    parseJSON o = parseURI o <|> parseURISimple o
      where
        parseURISimple s@(String _) = do
            _uriValue <- parseJSON s
            return URI { _uriSetExec = Nothing
                       , _uriExtract = Nothing
                       , ..}
        parseURI (Object o) = do
            _uriValue   <- o .: "uri"
            _uriSetExec <- o .:? "executable"
            _uriExtract <- o .:? "extract"
            return URI {..}

instance FromJSON URIList where
    parseJSON (Array a) = URIList <$> mapM parseJSON (V.toList a)

instance FromJSON Volume where
    parseJSON (Object o) = do
        _volHostPath      <- o .:? "hostPath"
        _volContainerPath <- o .: "containerPath"
        _volReadOnly      <- o .:? "readOnly" .!= False
        return Volume {..}

instance FromJSON VolumeList where
    parseJSON (Array a) = VolumeList <$> mapM parseJSON (V.toList a)

instance FromJSON ContainerConf where
    parseJSON = parseDocker
      where
        parseDocker (Object o) = do
            docker         <- o .: "docker"
            _dockerImage   <- docker .: "image"
            _dockerVolumes <- docker .: "volumes"
            return DockerConf {..}

instance FromJSON CommandSpec where
    parseJSON (String s) = return $ ShellCommand s
    parseJSON (Array a)  = parseExec (V.head a) (V.tail a)
      where
        parseExec (String x) xs = ExecCommand x <$> mapM parseJSON (V.toList xs)

instance FromJSON CommandConf where
    parseJSON (Object o) = do
        _ccRun       <- o .: "run"
        _ccURIs      <- o .:? "uris"
        _ccEnv       <- o .:? "env"
        _ccUser      <- o .:? "user"
        _ccExecutor  <- o .:? "executor"
        _ccContainer <- o .:? "container"
        return CommandConf {..}
