{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Servus.Options where

import           Options.Applicative

data GlobalOpts = GlobalOpts
    { _configFile  :: FilePath
    }

defaultOpts :: GlobalOpts
defaultOpts = GlobalOpts ""

globalOptsParser :: Parser GlobalOpts
globalOptsParser = GlobalOpts <$> strOption conf
  where
    GlobalOpts {..} = defaultOpts
    conf = long "config-file" <> short 'c' <> value _configFile
        <> help "servus configuration file" <> metavar "CONFIG.YAML" 
