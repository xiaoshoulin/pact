{-# LANGUAGE TupleSections #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}

-- |
-- Module      :  Pact.ApiReq
-- Copyright   :  (C) 2016 Stuart Popejoy
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Stuart Popejoy <stuart@kadena.io>
--

module Pact.ApiReq
    (
     KeyPair(..)
    ,ApiReq(..)
    ,apiReq
    ,mkApiReq
    ,mkExec
    ,mkCont
    ) where

import Control.Monad.State.Strict
import Control.Monad.Catch
import Data.List
import Prelude
import System.Directory
import System.FilePath
import Data.Aeson
import GHC.Generics
import qualified Data.Yaml as Y
import qualified Data.ByteString.Lazy.Char8 as BSL
import Data.Text (Text,pack)
import Data.Text.Encoding
import Data.Thyme.Clock
import qualified Data.Set as S

import Crypto.Ed25519.Pure

import Pact.Types.Crypto
import Pact.Types.Util
import Pact.Types.Command
import Pact.Types.RPC
import Pact.Types.Runtime hiding (PublicKey)
import Pact.Types.API


data KeyPair = KeyPair {
  _kpSecret :: PrivateKey,
  _kpPublic :: PublicKey
  } deriving (Eq,Show,Generic)
instance ToJSON KeyPair where toJSON = lensyToJSON 3
instance FromJSON KeyPair where parseJSON = lensyParseJSON 3

data ApiReq = ApiReq {
  _ylType :: Maybe String,
  _ylTxId :: Maybe TxId,
  _ylStep :: Maybe Int,
  _ylRollback :: Maybe Bool,
  _ylResume :: Maybe Value,
  _ylData :: Maybe Value,
  _ylDataFile :: Maybe FilePath,
  _ylCode :: Maybe String,
  _ylCodeFile :: Maybe FilePath,
  _ylKeyPairs :: [KeyPair],
  _ylNonce :: Maybe String,
  _ylFrom :: Maybe EntityName,
  _ylTo :: Maybe [EntityName]
  } deriving (Eq,Show,Generic)
instance ToJSON ApiReq where toJSON = lensyToJSON 3
instance FromJSON ApiReq where parseJSON = lensyParseJSON 3

apiReq :: FilePath -> Bool -> IO ()
apiReq fp local = do
  (_,exec) <- mkApiReq fp
  if local then
    BSL.putStrLn $ encode exec
    else
    BSL.putStrLn $ encode $ SubmitBatch [exec]
  return ()

mkApiReq :: FilePath -> IO ((ApiReq,String,Value,Maybe Address),Command Text)
mkApiReq fp = do
  ar@ApiReq {..} <- either (dieAR . show) return =<<
                 liftIO (Y.decodeFileEither fp)
  case _ylType of
    Just "exec" -> mkApiReqExec ar fp
    Just "cont" -> mkApiReqCont ar fp
    Nothing     -> mkApiReqExec ar fp -- Default
    _      -> dieAR "Expected a valid message type: either 'exec' or 'cont'"


mkApiReqExec :: ApiReq -> FilePath -> IO ((ApiReq,String,Value,Maybe Address),Command Text)
mkApiReqExec ar@ApiReq{..} fp = do
  (code,cdata) <- withCurrentDirectory (takeDirectory fp) $ do
    code <- case (_ylCodeFile,_ylCode) of
      (Nothing,Just c) -> return c
      (Just f,Nothing) -> liftIO (readFile f)
      _ -> dieAR "Expected either a 'code' or 'codeFile' entry"
    cdata <- case (_ylDataFile,_ylData) of
      (Nothing,Just v) -> return v -- either (\e -> dieAR $ "Data decode failed: " ++ show e) return $ eitherDecode (BSL.pack v)
      (Just f,Nothing) -> liftIO (BSL.readFile f) >>=
                          either (\e -> dieAR $ "Data file load failed: " ++ show e) return .
                          eitherDecode
      (Nothing,Nothing) -> return Null
      _ -> dieAR "Expected either a 'data' or 'dataFile' entry, or neither"
    return (code,cdata)  
  addy <- case (_ylTo,_ylFrom) of
    (Just t,Just f) -> return $ Just (Address f (S.fromList t))
    (Nothing,Nothing) -> return Nothing
    _ -> dieAR "Must specify to AND from if specifying addresses"
  ((ar,code,cdata,addy),) <$> mkExec code cdata addy _ylKeyPairs _ylNonce

mkExec :: String -> Value -> Maybe Address -> [KeyPair] -> Maybe String -> IO (Command Text)
mkExec code mdata addy kps ridm = do
  rid <- maybe (show <$> getCurrentTime) return ridm
  return $ decodeUtf8 <$>
    mkCommand
    (map (\KeyPair {..} -> (ED25519,_kpSecret,_kpPublic)) kps)
    addy
    (pack $ show rid)
    (Exec (ExecMsg (pack code) mdata))

mkApiReqCont :: ApiReq -> FilePath -> IO ((ApiReq,String,Value,Maybe Address),Command Text)
mkApiReqCont ar@ApiReq{..} fp = do
  txId <- case _ylTxId of
    Just t  -> return t
    Nothing -> dieAR "Expected a 'txid' entry"
    
  step <- case _ylStep of
    Just s  -> return s
    Nothing -> dieAR "Expected a 'step' entry"
    
  rollback <- case _ylRollback of
    Just r  -> return r
    Nothing -> dieAR "Expected a 'rollback' entry"

  cdata <- withCurrentDirectory (takeDirectory fp) $ do
    case (_ylDataFile,_ylData) of
      (Nothing,Just v) -> return v -- either (\e -> dieAR $ "Data decode failed: " ++ show e) return $ eitherDecode (BSL.pack v)
      (Just f,Nothing) -> liftIO (BSL.readFile f) >>=
                          either (\e -> dieAR $ "Data file load failed: " ++ show e) return .
                          eitherDecode
      (Nothing,Nothing) -> return Null
      _ -> dieAR "Expected either a 'data' or 'dataFile' entry, or neither" 
  addy <- case (_ylTo,_ylFrom) of
    (Just t,Just f) -> return $ Just (Address f (S.fromList t))
    (Nothing,Nothing) -> return Nothing
    _ -> dieAR "Must specify to AND from if specifying addresses"

  ((ar,"",cdata,addy),) <$> mkCont txId step rollback cdata addy _ylKeyPairs _ylNonce

mkCont :: TxId -> Int -> Bool  -> Value -> Maybe Address -> [KeyPair]
  -> Maybe String -> IO (Command Text)
mkCont txid step rollback mdata addy kps ridm = do
  rid <- maybe (show <$> getCurrentTime) return ridm
  return $ decodeUtf8 <$>
    mkCommand
    (map (\KeyPair {..} -> (ED25519,_kpSecret,_kpPublic)) kps)
    addy
    (pack $ show rid)
    (Continuation (ContMsg txid step rollback mdata) :: (PactRPC ContMsg))

dieAR :: String -> IO a
dieAR errMsg = throwM . userError $ "Failure reading request yaml. Yaml file keys: \n\
  \  code: Transaction code \n\
  \  codeFile: Transaction code file \n\
  \  data: JSON transaction data \n\
  \  dataFile: JSON transaction data file \n\
  \  keyPairs: list of key pairs for signing (use seal -g to generate): [\n\
  \    public: base 16 public key \n\
  \    secret: base 16 secret key \n\
  \    ] \n\
  \  nonce: optional request nonce, will use current time if not provided \n\
  \  from: entity name for addressing private messages \n\
  \  to: entity names for addressing private messages \n\
  \Error message: " ++ errMsg
