{-# LANGUAGE DeriveGeneric #-}
-- Data model for reports returned by the quid2.net server
module Model.Report (NestedReport(..),WarpReport(..),ByTypeReport(..),ClientReport(..),Time(..)) where
import Data.Time.Util
import Data.Time.Clock
import Data.Typed
import Data.Word

data WarpReport = WarpReport {
  version::String
  ,startTime::Time
  ,numOpenedConnections::Word64
  ,numClosedConnections::Word64
  } deriving (Eq,Ord,Show,Generic)

instance Flat Time
instance Model Time
instance Flat WarpReport
instance Model WarpReport

data NestedReport a = NestedReport String a [NestedReport a] deriving (Eq,Ord,Show,Generic)
instance Flat a => Flat (NestedReport a)
instance Model a => Model (NestedReport a)

data ByTypeReport = ByTypeReport [(AbsType,ClientReport)] deriving (Eq,Ord,Show,Generic)
instance Flat ByTypeReport
instance Model ByTypeReport

data ClientReport = ClientReport {clientID::Integer,clientStartTime::Time} deriving (Show,Eq,Ord,Generic)
instance Flat ClientReport
instance Model ClientReport
