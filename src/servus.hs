{-# LANGUAGE OverloadedStrings #-}
module Main where

import           Control.Concurrent.STM
import qualified Data.ByteString.Char8  as C
import qualified Data.Map               as M
import           System.Mesos.Scheduler

data ServusJob = ServusJob
    { _sjName        :: JobName
    , _sjConstraints :: JobConstraintExpr
    }
  deriving (Show)

readyJobs   = newTVarIO :: IO (TVar JobConstraintMinHeap)
activeJobs  = newTVarIO :: IO (TVar [ActiveServusJob])
expiredJobs = newTVarIO :: IO (TVar [ExpiredServusJob])

data ServusScheduler = ServusScheduler
    { _ssJobDefs     :: M.Map JobName ServusJob
    , _ssReadyJobs   :: IO (TVar JobConstraintMinHeap)
    , _ssActiveJobs  :: IO (TVar [ActiveJobs])
    , _ssExpiredJobs :: IO (TVar [ExpiredServusJob])
    }

instance ToScheduler ServusScheduler where
    registered _ _ _ _ _ = putStrLn "register"

    resourceOffers s driver offers = do
        forM_ offers $ \offer -> do
            case (matchOffer offer $ _ssReadyJobs s) of
                MatchedOffer job -> do
                    status <- launchTasks
                        driver
                        [ offerID offer ]
                        ...
                    putStrLn "Launched job " ++ (_sjName job)
                _                -> do
                    declineOffer driver (offerID offer) filters -- TODO: WTF is filters?
                    putStrLn "Declined offer " ++ (show $ offerID offer)
        return ()

main = do
    ...
