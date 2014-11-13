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
import           System.Log.FastLogger

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
        _log   <- newStderrLoggerSet defaultBufSize
        _conf  <- either def return =<< parseServusConf c
        _state <- newServerState _log _conf

        forkThread _threads $ morticianLoop _state
        forkThread _threads $ mesosFrameworkLoop _state
        forkThread _threads $ restApiLoop _state

        waitFor _threads
        rmLoggerSet _log

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
