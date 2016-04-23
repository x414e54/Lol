{-# LANGUAGE FlexibleContexts, NoImplicitPrelude, PartialTypeSignatures,
             RebindableSyntax, RecordWildCards, ScopedTypeVariables,
             TypeFamilies #-}

module Generate (generateMain, ChallengeParams(..)) where

import           Beacon
import           Common
import           Crypto.Challenges.RLWE.Continuous               as C
import           Crypto.Challenges.RLWE.Discrete                 as D
import           Crypto.Challenges.RLWE.Proto.RLWE.Challenge
import qualified Crypto.Challenges.RLWE.Proto.RLWE.ChallengeType as P
import           Crypto.Challenges.RLWE.Proto.RLWE.InstanceCont
import           Crypto.Challenges.RLWE.Proto.RLWE.InstanceDisc
import           Crypto.Challenges.RLWE.Proto.RLWE.InstanceRLWR
import           Crypto.Challenges.RLWE.Proto.RLWE.SampleCont
import           Crypto.Challenges.RLWE.Proto.RLWE.SampleDisc
import           Crypto.Challenges.RLWE.Proto.RLWE.SampleRLWR
import           Crypto.Challenges.RLWE.Proto.RLWE.Secret        as S
import           Crypto.Challenges.RLWE.RLWR                     as R

import Control.Applicative
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Random

import Crypto.Lol                    hiding (lift, RRq)
import Crypto.Lol.Cyclotomic.UCyc
import Crypto.Lol.Types.Proto
import Crypto.Lol.Types.Proto.Lol.Kq
import Crypto.Lol.Types.Proto.Lol.Rq
import Crypto.Lol.Types.Random
import Crypto.Random.DRBG

import Data.ByteString.Lazy as BS (writeFile)
import Data.Reflection      hiding (D)

import System.Directory (createDirectoryIfMissing)

import Text.ProtocolBuffers        (messagePut)
import Text.ProtocolBuffers.Header

-- | Information to generate a challenge.
data ChallengeParams =
    Cont {numSamples::Int, numInsts::Int32, m::Int32, q::Int64,
          svar::Double, eps::Double}
  | Disc {numSamples::Int, numInsts::Int32, m::Int32, q::Int64,
          svar::Double, eps::Double}
  | RLWR {numSamples::Int, numInsts::Int32, m::Int32, q::Int64, p::Int64}

-- Tensor type used to generate instances
type T = CT

-- | Generate and serialize challenges given the path to the root of the tree
-- and an initial beacon address.
generateMain :: FilePath -> BeaconAddr -> [ChallengeParams] -> IO ()
generateMain path beaconStart cps = do
  let challIDs = [0..]
      beaconAddrs = iterate nextBeaconAddr beaconStart
      challNames = map challengeName cps
  evalCryptoRandIO (sequence_ $
    zipWith3 (genAndWriteChallenge path) cps challIDs beaconAddrs :: _ (CryptoRand HashDRBG) _ _)

genAndWriteChallenge :: (MonadRandom m, MonadIO m)
  => FilePath -> ChallengeParams -> Int32 -> BeaconAddr -> m ()
genAndWriteChallenge path cp challID ba = do
  chall <- genChallengeU cp challID ba
  let name = challengeName cp
  liftIO $ putStrLn $ "Generating challenge " ++ name
  liftIO $ writeChallengeU path name chall

-- | The name for each challenge directory.
challengeName :: ChallengeParams -> FilePath
challengeName Cont{..} =
  "chall-rlwec-m" ++ show m ++ "-q" ++ show q ++ "-v" ++ show svar
challengeName Disc{..} =
  "chall-rlwed-m" ++ show m ++ "-q" ++ show q ++ "-v" ++ show svar
challengeName RLWR{..} =
  "chall-rlwr-m" ++ show m ++ "-q" ++ show q ++ "-p" ++ show p

-- | Generate a challenge with the given parameters.
genChallengeU :: (MonadRandom rnd)
  => ChallengeParams -> Int32 -> BeaconAddr -> rnd ChallengeU
genChallengeU cp challID ba = do
  let chall = toProtoChallenge cp challID ba
  insts <- mapM (genInstanceU cp challID) [0..]
  return $ CU chall $ take (fromIntegral $ numInsts cp) insts

-- | Generate an RLWE instance with the given parameters.
genInstanceU :: (MonadRandom rnd)
  => ChallengeParams -> Int32 -> Int32 -> rnd InstanceU
genInstanceU cp@Cont{..} challID instID = reify q (\(_::Proxy q) ->
  reifyFactI (fromIntegral m) (\(_::proxy m) -> do
    (s, samples :: [C.Sample T m (Zq q) (RRq q)]) <- C.instanceN svar numSamples
    let s' = toProtoSecret challID instID m q s
        inst = toProtoInstanceCont challID instID cp samples
    return $ IC s' inst))
genInstanceU cp@Disc{..} challID instID = reify q (\(_::Proxy q) ->
  reifyFactI (fromIntegral m) (\(_::proxy m) -> do
    (s, samples :: [D.Sample T m (Zq q)]) <- D.instanceN svar numSamples
    let s' = toProtoSecret challID instID m q s
        inst = toProtoInstanceDisc challID instID cp samples
    return $ ID s' inst))
genInstanceU cp@RLWR{..} challID instID = reify q (\(_::Proxy q) ->
  reify p (\(_::Proxy p) -> reifyFactI (fromIntegral m) (\(_::proxy m) -> do
    (s, samples :: [R.Sample T m (Zq q) (Zq p)]) <- R.instanceN numSamples
    let s' = toProtoSecret challID instID m q s
        inst = toProtoInstanceRLWR challID instID cp samples
    return $ IR s' inst)))

-- | Constructs an unstructured 'Challenge' suitable for serialization.
toProtoChallenge :: ChallengeParams -> Int32 -> BeaconAddr -> Challenge
toProtoChallenge cp challengeID (BA beaconTime beaconOffset) =
  let numInstances = numInsts cp
  in case cp of
    Cont{..} -> Challenge{challType = P.Cont,..}
    Disc{..} -> Challenge{challType = P.Disc,..}
    RLWR{..} -> Challenge{challType = P.RLWR,..}

-- | Constructs an unstructured 'InstanceCont' suitable for serialization.
toProtoInstanceCont :: forall t m zq rrq .
  (Fact m,
   Protoable (Cyc t m zq), ProtoType (Cyc t m zq) ~ Rq,
   Protoable (UCyc t m D rrq), ProtoType (UCyc t m D rrq) ~ Kq)
  => Int32 -> Int32 -> ChallengeParams -> [C.Sample t m zq rrq] -> InstanceCont
toProtoInstanceCont challengeID instID Cont{..} samples' =
  let bound = proxy (C.computeBound svar eps) (Proxy::Proxy m)
      samples = (uncurry SampleCont) <$> (toProto samples')
  in InstanceCont{..}

-- | Constructs an unstructured 'InstanceDisc' suitable for serialization.
toProtoInstanceDisc :: forall t m zq rrq .
  (Fact m, Protoable (Cyc t m zq), ProtoType (Cyc t m zq) ~ Rq)
  => Int32 -> Int32 -> ChallengeParams -> [D.Sample t m zq] -> InstanceDisc
toProtoInstanceDisc challengeID instID Disc{..} samples' =
  let bound = proxy (D.computeBound svar eps) (Proxy::Proxy m)
      samples = (uncurry SampleDisc) <$> (toProto samples')
  in InstanceDisc{..}

-- | Constructs an unstructured 'InstanceRLWR' suitable for serialization.
toProtoInstanceRLWR ::
  (Fact m,
   Protoable (Cyc t m zq), ProtoType (Cyc t m zq) ~ Rq,
   Protoable (Cyc t m zq'), ProtoType (Cyc t m zq') ~ Rq)
  => Int32 -> Int32 -> ChallengeParams
     -> [R.Sample t m zq zq'] -> InstanceRLWR
toProtoInstanceRLWR challengeID instID RLWR{..} samples' =
  let samples = (uncurry SampleRLWR) <$> (toProto samples')
  in InstanceRLWR{..}

-- | Constructs an unstructured 'Secret' suitable for serialization.
toProtoSecret :: (Protoable (Cyc t m zq), ProtoType (Cyc t m zq) ~ Rq)
  => Int32 -> Int32 -> Int32 -> Int64 -> Cyc t m zq -> Secret
toProtoSecret challengeID instID m q s' = Secret{s = toProto s', ..}

-- | Writes a 'ChallengeU' to a file given a path to the root of the tree
-- and the name of the challenge.
writeChallengeU :: FilePath -> String -> ChallengeU -> IO ()
writeChallengeU path challName (CU c insts) = do
  let challDir = challengeFilesDir path
      challFN = challFilePath path challName
  createDirectoryIfMissing True challDir
  writeProtoType challFN c
  mapM_ (writeInstanceU path challName) insts

-- | Writes an 'InstanceU' to a file given a path to the root of the tree
-- and the name of the challenge.
writeInstanceU :: FilePath -> String -> InstanceU -> IO ()
writeInstanceU path challName iu = do
  let s = secret iu
      idx = S.instID s
      instFN = instFilePath path challName idx
      secretFN = secretFilePath path challName idx
  case iu of
    (IC _ inst) -> writeProtoType instFN inst
    (ID _ inst) -> writeProtoType instFN inst
    (IR _ inst) -> writeProtoType instFN inst
  writeProtoType secretFN s

-- | Writes any auto-gen'd proto object to path/filename.
writeProtoType :: (ReflectDescriptor a, Wire a) => FilePath -> a -> IO ()
writeProtoType fileName obj = do
  putStr "."
  BS.writeFile fileName $ messagePut obj