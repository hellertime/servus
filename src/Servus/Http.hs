{-# LANGUAGE OverloadedStrings #-}

module Servus.Http where

import           Control.Concurrent.STM
import           Control.Monad.Reader
import           Data.Aeson
import qualified Data.Map.Strict                     as M
import           Data.Monoid                                 ((<>))
import           Data.Text.Lazy                              (Text, empty)
import           Network.Wai.Middleware.RequestLogger
import           Web.Scotty.Trans
import qualified Web.Scotty.Trans                     as WST

import Servus.Config
import Servus.Server
import Servus.Task

newtype HalTaskLibrary = HalTaskLibrary TaskLibrary

instance ToJSON HalTaskLibrary where
    toJSON (HalTaskLibrary (TaskLibrary tl)) = object [ "_links" .= hal ]
      where
        hal = object $ [ "self"          .= object [ "href" .= ("/" <> empty) ]
                       , "curies"        .= curies
                       , "x:taskLibrary" .= tasks
                       ]
        curies = [ object [ "name" .= ("x" <> empty), "href" .= ("xxx" <> empty), "templated" .= True ] ]
        tasks = object $ map toLink $ M.keys tl
        toLink (name, SystemTask)    = "href" .= ("/taskLibrary/system/" <> name)
        toLink (name, UserTask owner) = "href" .= ("/taskLibrary/user/" <> owner <> "/" <> name)

restApi :: ScottyT Text TaskM ()
restApi = do
    middleware logStdoutDev
    get "/" $ do
       library <- taskM $ ask >>= liftIO . atomically . readTVar . _library
       WST.json $ HalTaskLibrary library
