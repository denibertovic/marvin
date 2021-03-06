{-|
Module      : $Header$
Description : Adapter for communicating with Slack via its real time messaging API
Copyright   : (c) Justus Adam, 2016
License     : BSD3
Maintainer  : dev@justus.science
Stability   : experimental
Portability : POSIX

See http://marvin.readthedocs.io/en/latest/adapters.html#real-time-messaging-api for documentation of this adapter.
-}
module Marvin.Adapter.Slack.RTM
    ( SlackAdapter, RTM
    , SlackUserId(..), SlackChannelId(..)
    , MkSlack
    , SlackRemoteFile(..), SlackLocalFile(..)
    , HasTitle(..), HasPublicPermalink(..), HasEditable(..), HasPublic(..), HasUser(..), HasPrivateUrl(..), HasComment(..)
    ) where


import           Control.Concurrent.Async.Lifted      (async, link)
import           Control.Concurrent.Chan.Lifted
import           Control.Concurrent.MVar.Lifted
import           Control.Exception.Lifted
import           Control.Monad
import           Control.Monad.Except
import           Control.Monad.Logger
import           Data.Aeson                           hiding (Error)
import           Data.Aeson.Types                     hiding (Error)
import qualified Data.ByteString.Lazy.Char8           as BS
import           Data.IORef.Lifted
import           Data.Maybe                           (fromMaybe)
import qualified Data.Text                            as T
import           Lens.Micro.Platform                  hiding ((.=))
import           Marvin.Adapter
import           Marvin.Adapter.Slack.Internal.Common
import           Marvin.Adapter.Slack.Internal.Types
import           Marvin.Interpolate.Text
import           Network.URI
import           Network.WebSockets
import           Network.Wreq
import           Text.Read                            (readMaybe)
import           Wuss


runConnectionLoop :: Chan (InternalType RTM) -> MVar Connection -> AdapterM (SlackAdapter RTM) ()
runConnectionLoop eventChan connectionTracker = do
    messageChan <- newChan
    a <- async $ forever $ do
        msg <- readChan messageChan
        case eitherDecode msg >>= parseEither eventParser of
            -- changed it do logDebug for now as we still have events that we do not handle
            -- all those will show up as errors and I want to avoid polluting the log
            -- once we are sure that all events are handled in some way we can make this as error again
            -- (which it should be)
            Left e  -> logDebugN $(isT "Error parsing json: #{e} original data: #{rawBS msg}")
            Right v -> writeChan eventChan v
    link a
    forever $ do
        token <- requireFromAdapterConfig "token"
        logDebugN "initializing socket"
        r <- liftIO $ post "https://slack.com/api/rtm.start" [ "token" := (token :: T.Text) ]
        case eitherDecode (r^.responseBody) of
            Left err -> do
                logErrorN $(isT "Error decoding rtm json #{err}")
                logDebugN $(isT "#{r^.responseBody}")
            Right js -> do
                port <- case uriPort authority_ of
                            v@(':':rest_) -> maybe (portOnErr v) return $ readMaybe rest_
                            v             -> portOnErr v
                logDebugN $(isT "connecting to socket '#{uri}'")
                logFn <- askLoggerIO

                liftIO $ runSecureClient host port path_ $ \conn -> flip runLoggingT logFn $ do
                    logInfoN "Connection established"
                    d <- liftIO $ receiveData conn
                    case eitherDecode d >>= parseEither helloParser of
                        Right True -> logDebugN "Recieved hello packet"
                        Left _ -> error $ "Hello packet not readable: " ++ BS.unpack d
                        _ -> error $ "First packet was not hello packet: " ++ BS.unpack d
                    putMVar connectionTracker conn
                    forever $ do
                        data_ <- liftIO $ receiveData conn
                        writeChan messageChan data_
                `catch` \e -> do
                    void $ takeMVar connectionTracker
                    logErrorN $(isT "#{e :: ConnectionException}")
              where
                uri = url js
                authority_ = fromMaybe (error "URI lacks authority") (uriAuthority uri)
                host = uriUserInfo authority_ ++ uriRegName authority_
                path_ = uriPath uri
                portOnErr v = do
                    logWarnN $(isT "Port unreadable \"#{v}\", trying standard port 443")
                    return 443


senderLoop :: MVar Connection -> AdapterM (SlackAdapter a) ()
senderLoop connectionTracker = do
    outChan <- view (adapter.outChannel)
    midTracker <- newIORef (0 :: Int)
    forever $ do
        (SlackChannelId sid, msg) <- readChan outChan
        mid <- atomicModifyIORef' midTracker (\i -> (i+1, i))
        let encoded = encode $ object
                [ "id" .= mid
                , "type" .= ("message" :: T.Text)
                , "channel" .= sid
                , "text" .= msg
                ]

            tryConn =
                withMVar connectionTracker (liftIO . flip sendTextData encoded)
                `catch` \e -> do
                    logErrorN $(isT "#{e :: ConnectionException}")
                    throwError ()

        either (const $ logErrorN "Connection error, quitting retry.") return =<< runExceptT (msum (replicate 3 tryConn))


-- | Recieve events by opening a websocket to the Real Time Messaging API
data RTM


instance MkSlack RTM where
    mkAdapterId = "slack-rtm"
    initIOConnections inChan = do
        connTracker <- newEmptyMVar
        a <- async $ runConnectionLoop inChan connTracker
        link a
        senderLoop connTracker
