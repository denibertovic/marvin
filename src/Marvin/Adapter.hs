{-# LANGUAGE ExplicitForAll      #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Marvin.Adapter where

import           ClassyPrelude
import qualified Data.Configurator.Types as C
import           Marvin.Internal.Types
import qualified System.Log.Logger       as L

data Event
    = MessageEvent Message

type EventHandler a = a -> Event -> IO ()


class IsAdapter a where
    adapterId :: AdapterId a
    messageRoom :: a -> Room -> Text -> IO ()
    getUserInfo :: a -> User -> IO (Maybe UserInfo)
    runWithAdapter :: RunWithAdapter a


type RunWithAdapter a = C.Config -> EventHandler a -> IO ()



adapterLog :: forall m a. (MonadIO m, IsAdapter a) => (String -> String -> IO ()) -> a -> Text -> m ()
adapterLog inner _ message =
    liftIO $ inner (unpack $ "adapter." ++ aid) (unpack message)
  where (AdapterId aid) = adapterId :: AdapterId a


debugM, infoM, noticeM, warningM, errorM, criticalM, alertM, emergencyM :: (MonadIO m, IsAdapter a) => a -> Text -> m ()
debugM = adapterLog L.debugM
infoM = adapterLog L.infoM
noticeM = adapterLog L.noticeM
warningM = adapterLog L.warningM
errorM = adapterLog L.errorM
criticalM = adapterLog L.criticalM
alertM = adapterLog L.alertM
emergencyM = adapterLog L.emergencyM


logM :: (MonadIO m, IsAdapter a) => L.Priority -> a -> Text -> m ()
logM prio = adapterLog (`L.logM` prio)