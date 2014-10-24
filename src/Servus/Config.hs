{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Servus.Config where

import           Control.Applicative
import           Control.Monad               (sequence)
import           Data.Aeson                  (fromJSON)
import qualified Data.HashMap.Lazy    as HML (lookup, toList, keys, elems, member)
import           Data.Maybe                  (listToMaybe, fromMaybe)
import qualified Data.Text            as T   (unpack)
import qualified Data.Vector          as V   (toList, head, tail)
import           Data.Yaml
import qualified System.Mesos.Types   as M

import Data.Vector (Vector)

parseServusConf :: FilePath -> IO (Maybe ServusConf)
parseServusConf = decodeFile

data ServusConf = ServusConf
    { _scGlobal    :: Maybe GlobalConf
    , _scFramework :: Maybe FrameworkConf
    , _scTasks     :: [TaskConf]
    }
  deriving (Show)

data GlobalConf = GlobalConf
    { _gcMaster :: String
    }
  deriving (Show)

data FrameworkConf = FrameworkConf
    { _fcName            :: String
    , _fcUser            :: String
    , _fcFailoverTimeout :: Maybe Double
    , _fcCheckpoint      :: Maybe Bool
    , _fcRole            :: Maybe String
    , _fcHostname        :: Maybe String
    , _fcPrincipal       :: Maybe String
    }
  deriving (Show)

data Resource = Scalar Double
              | Ranges [(Integer, Integer)]
              | Set [String]
              | Text String
              deriving (Show)

data ResourceList = ResourceList
    { _rsrcs :: [(String, Resource)]
    }
  deriving (Show)

data EnvVars = EnvVars
    { _evs :: [(String, String)]
    }
  deriving (Show)

data URI = URI
    { _uriValue   :: String
    , _uriSetExec :: Maybe Bool
    , _uriExtract :: Maybe Bool
    }
  deriving (Show)

data URIList = URIList [URI]
  deriving (Show)

data ExecutorConf = ExecutorConf
    { _execName      :: String
    , _execResources :: Maybe ResourceList
    }
  deriving (Show)

data Volume = Volume
    { _volHostPath      :: Maybe String
    , _volContainerPath :: String
    , _volReadOnly      :: Bool
    }
  deriving (Show)

data VolumeList = VolumeList [Volume]
  deriving (Show)

data ContainerConf = DockerConf
    { _dockerImage   :: String
    , _dockerVolumes :: VolumeList
    }
  deriving (Show)

data CommandSpec = ShellCommand String
                 | ExecCommand String [String]
                 deriving (Show)

data CommandConf = CommandConf
    { _ccRun       :: CommandSpec
    , _ccURIs      :: Maybe URIList
    , _ccEnv       :: Maybe EnvVars
    , _ccUser      :: Maybe String
    , _ccExecutor  :: Maybe ExecutorConf
    , _ccContainer :: Maybe ContainerConf
    }
  deriving (Show)

data TriggerConf = TriggerConf
    { _tcRemote       :: Bool
    , _tcMaxInstances :: Integer
    , _tcLaunchRate   :: Double
    , _tcScheduleExpr :: Maybe String
    }
  deriving (Show)

defaultTrigger = TriggerConf True 1 1.0 Nothing

data TaskConf = TaskConf
    { _tcName          :: String
    , _tcCommand       :: CommandConf
    , _tcTrigger       :: TriggerConf
    , _tcResources     :: Maybe ResourceList
    }
  deriving (Show)

instance FromJSON ServusConf where
    parseJSON (Object o) = do
        _scGlobal    <- o .:? "global"
        _scFramework <- o .:? "framework"
        _scTasks     <- o .: "tasks"
        return ServusConf {..}

instance FromJSON GlobalConf where
    parseJSON (Object o) = GlobalConf <$> o .:? "mesosMaster" .!= "127.0.0.1:5050"

instance FromJSON FrameworkConf where
    parseJSON (Object o) = do
        _fcUser            <- o .:? "user" .!= ""
        _fcFailoverTimeout <- o .:? "failoverTimeout"
        _fcCheckpoint      <- o .:? "checkpoint"
        _fcRole            <- o .:? "role"
        _fcHostname        <- o .:? "hostname"
        _fcPrincipal       <- o .:? "principal"
        return FrameworkConf { _fcName = "servus"
                             , .. }

instance FromJSON TriggerConf where
    parseJSON (Object o) = do
        _tcRemote       <- o .:? "remote" .!= (if HML.member "schedule" o then False else True)
        _tcMaxInstances <- o .:? "maxInstances" .!= 1
        _tcLaunchRate   <- o .:? "launchRate" .!= 1.0
        _tcScheduleExpr <- o .:? "schedule"
        return TriggerConf {..}

instance FromJSON TaskConf where
    parseJSON (Object o) = do
        _tcName      <- o .: "name"
        _tcCommand   <- o .: "command"
        _tcResources <- o .:? "resources"
        maybeTrigger <- o .:? "trigger"
        return TaskConf { _tcTrigger = fromMaybe defaultTrigger maybeTrigger
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
        k <- return $ map T.unpack $ HML.keys o
        v <- mapM parseJSON $ HML.elems o
        return $ ResourceList (zip k v)

instance FromJSON EnvVars where
    parseJSON (Object o) = do
        k <- return $ map T.unpack $ HML.keys o
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
    parseJSON (String s) = return $ ShellCommand $ T.unpack s
    parseJSON (Array a)  = parseExec (V.head a) (V.tail a)
      where
        parseExec (String x) xs = ExecCommand (T.unpack x) <$> mapM parseJSON (V.toList xs)

instance FromJSON CommandConf where
    parseJSON (Object o) = do
        _ccRun       <- o .: "run"
        _ccURIs      <- o .:? "uris"
        _ccEnv       <- o .:? "env"
        _ccUser      <- o .:? "user"
        _ccExecutor  <- o .:? "executor"
        _ccContainer <- o .:? "container"
        return CommandConf {..}
