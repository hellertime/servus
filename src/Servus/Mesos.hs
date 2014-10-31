{-# LANGUAGE OverloadedStrings #-}

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

-- | Define the mesos scheduler directly over the server state
instance ToScheduler ServerState where
    registered server _ _ _ = T.putStrLn $ (_mcName $ _scMesos $ _conf server) <> ": registered"

    resourceOffers server driver offers = do
        readyOfferGroups <- matchOffers offers server
        forM_ readyOfferGroups $ \readyOfferGroup -> do
            runTasks readyOfferGroup server $ \offers tasks -> do
                launchTasks driver offers tasks (Filters Nothing)

mesosFrameworkLoop :: ServerState -> IO ()
mesosFrameworkLoop server = do 
    stopStatus <- withSchedulerDriver server framework master creds $ \driver -> do
        runStatus <- run driver
        stop driver shouldRestart
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
