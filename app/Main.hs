-- -*- mode:org;mode:haskell; -*-
{-# LANGUAGE CPP                  #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE TemplateHaskell      #-}
{-# LANGUAGE TupleSections        #-}
{-# LANGUAGE TypeSynonymInstances ,DeriveGeneric #-}
module Main where

import           Control.Concurrent                   (MVar, modifyMVar,
                                                       modifyMVar_, newMVar,
                                                       readMVar)
import           Control.Exception                    (fromException, handle)
import           Control.Monad

import qualified Data.ByteString.Lazy                 as L
import           Data.FileEmbed                       (embedDir)
import qualified Data.Text.Lazy                       as T
import qualified Network.Wai
import qualified Network.Wai.Application.Static       as Static
import qualified Network.Wai.Handler.Warp             as Warp
import qualified Network.Wai.Handler.WebSockets       as WaiWS
import           Network.Wai.Middleware.RequestLogger (logStdoutDev)
import qualified Network.WebSockets                   as WS
import           Pandoc.Report
import           Quid2.Util.Service
import           Web.Scotty
import qualified Data.Map.Strict                      as M
import           Data.Word
import           Control.Applicative
import Data.Typed hiding (first)
import Data.Bifunctor
import Control.Monad.IO.Class
import Control.Concurrent.STM
import Data.Foldable (toList)
import Data.List
import Data.Maybe
import Network.Quid2 hiding (Config,first)
import Network.Router.Types
import Network.Router.Echo
import Network.Router.ByType
-- import System.Log
import System.Directory
import Data.Time.Util

{-
SOL: start manually as (already done by propellor):
killall -s SIGKILL quid2-net; /root/.cabal/bin/quid2-net > /dev/null 2>&1 &
-}
 {-
 Bug: quid2.net start won't work
 BUG: gets stuck after switching to websockets

 Switch pipe.

 Hosts all endpoints that require a fixed url address.

 http:80
 /  Return activity report.
?? /hook    HTTP call backs.

 https:443
 /ws       Accept WebSocket clients.

Max number of connections limited by ulimit -n , 1024 on Linux 256 on OSx

Vulnerabilities:
- no protection against denial of service attacks?
  --- huge messages
-}

serviceName = "quid2.net"

main = initService serviceName setup

setup :: Config () -> IO ()
setup cfg = do
  updateGlobalLogger rootLoggerName $ setLevel DEBUG -- INFO
  -- email titto serviceName "just started"

  -- Keep track of open/closed connections
  warpState <- newWarpState
  let onOpen sockAddr  = connOpened warpState >> dbg ["Connection Open",show sockAddr] >> return True
  let onClose sockAddr = connClosed warpState >> dbg ["Connection Close",show sockAddr]

  -- Setup routers
  echoRouter <- newEchoRouter
  byTypeRouter <- newByTypeRouter
  let routers = [echoRouter,byTypeRouter]
  let routersMap = foldr (\r -> M.insert (routerKey r) r) M.empty routers
  let version = unwords [__DATE__,__TIME__]
  startupTime <- getCurrentTime
  serverReport <- newServiceReport serviceName version startupTime (warpReport warpState : map routerReport routers)
  --asText serverReport >>= dbg1

  sapp :: Network.Wai.Application <- scottyApp $ do
     middleware logStdoutDev -- NOTE: output on stdout, not log file
     get "/" $ liftIO (T.pack <$> asHTML serverReport) >>= html
     get "/report" $ do
       r <- liftIO (flat <$> warpBinaryReport version startupTime warpState (mapM routerBinaryReport routers))
       setHeader "Access-Control-Allow-Origin" "*"
       setHeader "Content-Type" "application/octet-stream"
       raw r

  let warpOpts = Warp.setOnClose onClose . Warp.setOnOpen onOpen . Warp.setPort 8080 . Warp.setTimeout 60 $ Warp.defaultSettings

  connCounter <- newMVar 0
  Warp.runSettings warpOpts $ WaiWS.websocketsOr (WS.defaultConnectionOptions {WS.connectionOnPong=dbgS "Pong!"}) (application connCounter $ routersMap) sapp -- staticApp

-- Embedded static files
-- staticApp :: Network.Wai.Application
-- staticApp = Static.staticApp $ Static.embeddedSettings $(embedDir "static")

-- application :: MVar ServerState -> WS.ServerApp
application :: MVar Integer -> Routers -> WS.PendingConnection -> IO ()
application st routers pending = do
    let r = WS.pendingRequest pending
    dbg ["Pending websocket request",show r]

    conn <- WS.acceptRequestWith pending (WS.AcceptRequest $ Just "quid2.net")
    let done = failure conn

    when (WS.requestPath r /= "/ws") $ done ["WebSockets connection allowed only at /ws"]
    --when (not $ WS.requestSecure r)  $ done ["WebSockets request must be secure"]
    when (isNothing (find (== "quid2.net") (WS.getRequestSubprotocols r))) $ done ["Client must support WS protocol 'quid2.net'"]

    eProt <- WS.receiveData conn :: IO L.ByteString
    dbg ["header",show $ L.unpack eProt]
    case (unflat eProt) of
     Left e -> done ["Bad protocol type data",show e]
     Right (TypedBytes protType@(TypeApp rType vType) protBytes) -> do
       let bs = toList protBytes
       dbg ["got router type",show protType,show protBytes,show bs]
       case M.lookup rType routers of
        Just router -> do
          n <- connNum st
          client <- newClient n conn
          WS.forkPingThread conn 20
          routerHandler router vType bs client
        Nothing -> done ["Unsupported Quid2 Protocol",show protType]
 where
        failure conn reasons = do
          WS.sendClose conn $ T.pack . unwords $ ["Error while initialising connection:"] ++ reasons
          err reasons

-- unique connection number (in current server run)
connNum c = modifyMVar c (\n -> return (n+1,n))

 -- Number of opened and closed connections
type WarpState = MVar (Word64,Word64) 

newWarpState = newMVar (0,0)

connOpened warpState = modifyMVar_ warpState (return . first (+1))

connClosed warpState =  modifyMVar_ warpState (return . second (+1))

warpReport :: WarpState -> Report
warpReport warpState = report "Warp Server"
                       [("Currently open connections"  ,p . show . (\(o,c) -> o-c) <$> readMVar warpState)
                       ,("Closed Connections",p . show . snd <$> readMVar warpState)
                       ]

warpBinaryReport
  :: String
     -> UTCTime
     -> WarpState
     -> IO [NestedReport TypedBytes] -> IO (NestedReport TypedBytes)
warpBinaryReport version startupTime warpState subs = do
  (o,c) <- readMVar warpState
  NestedReport "Warp" (typedBytes $ WarpReport version (toTime startupTime) o c) <$> subs


-- t = absType (Proxy::Proxy WarpReport)
