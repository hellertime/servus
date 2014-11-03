{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}

module Servus.Mesos where

import           Control.Monad
import qualified Data.ByteString.Char8  as C8
import           Data.Functor                 (fmap)
import           Data.Monoid                  ((<>))
import qualified Data.Text.Encoding     as TE
import qualified Data.Text.IO           as T
import           System.Mesos.Scheduler
import           System.Mesos.Types

import Servus.Config
import Servus.Server

import Debug.Trace

-- | Define the mesos scheduler directly over the server state
instance ToScheduler ServerState where
    registered server driver fid info = T.putStrLn $ (_mcName $ _scMesos $ _conf server) <> ": registered"

    reRegistered server driver info = T.putStrLn $ (_mcName $ _scMesos $ _conf server) <> ": rereg"

    resourceOffers server driver offers = readyOffers >>= go
      where
        go = \case
               []     -> declineAll offers
               (o:os) -> runOffers o >> go os
        runOffers o = runTasks o server $ \o t -> launchTasks driver o t (Filters Nothing) 
        declineAll  = mapM_ $ \offer -> declineOffer driver (offerID offer) (Filters Nothing)
        readyOffers = matchOffers offers server
    
    statusUpdate server driver status = putStrLn $ "servus: task " <> show (taskStatusTaskID status) <> " is in state " <> show (taskStatusState status)

    errorMessage _ _ msg = C8.putStrLn msg

mesosFrameworkLoop :: ServerState -> IO ()
mesosFrameworkLoop server = do 
    putStrLn "NO DONE"
    stopStatus <- withSchedulerDriver server framework master creds $ \driver -> do
        runStatus <- run driver
        stop driver shouldRestart
    putStrLn "DONE"
    return ()
  where
    utf8          = TE.encodeUtf8
    mesos         = _scMesos $ _conf server
    user          = utf8 $ _mcUser mesos
    name          = utf8 $ _mcName mesos
    master        = utf8 $ _mcMaster mesos
    creds         = fmap (credential . utf8) $ _mcPrincipal mesos
    framework     = (frameworkInfo user name) { frameworkRole = fmap C8.pack $ _mcRole mesos }
    shouldRestart = _gcCluster $ _scGlobal $ _conf server
