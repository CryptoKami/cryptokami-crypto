{-# LANGUAGE OverloadedStrings #-}
module Main where

import           Control.Monad

import           Test.Tasty
import           Test.Tasty.QuickCheck

import qualified Crypto.Math.Edwards25519 as Edwards25519
import qualified Crypto.ECC.Ed25519Donna as EdVariant
import           Cryptokami.Crypto.Wallet
import           Cryptokami.Crypto.Wallet.Encrypted
import qualified Cryptokami.Crypto.Wallet.Pure as PureWallet
import qualified Data.ByteString as B
import qualified Data.ByteArray as B (convert)
import           Crypto.Error
import           Data.Word
import           Data.Bits

noPassphrase :: B.ByteString
noPassphrase = ""

dummyPassphrase :: B.ByteString
dummyPassphrase = "dummy passphrase"

newtype Passphrase = Passphrase B.ByteString
    deriving (Show,Eq)

data Ed = Ed Integer Edwards25519.Scalar

newtype Seed = Seed B.ByteString
    deriving (Show,Eq)

newtype ValidSeed = ValidSeed Seed
    deriving (Show,Eq)

newtype Message = Message B.ByteString
    deriving (Show,Eq)

newtype Salt = Salt B.ByteString
    deriving (Show,Eq)

p :: Integer
p = 2^(255 :: Int) - 19

q :: Integer
q = 2^(252 :: Int) + 27742317777372353535851937790883648493

instance Show Ed where
    show (Ed i _) = "Edwards25519.Scalar " ++ show i
instance Eq Ed where
    (Ed x _) == (Ed y _) = x == y
instance Arbitrary Ed where
    arbitrary = do
        n <- frequency
                [ (1, choose (q - 10000, q-1))
                , (1, choose (1, 1000))
                , (2, choose (1, q-1))
                ]
        return (Ed n (Edwards25519.scalarFromInteger n))
instance Arbitrary Message where
    arbitrary = Message . B.pack <$> (choose (0, 10) >>= \n -> replicateM n arbitrary)
instance Arbitrary Salt where
    arbitrary = Salt . B.pack <$> (choose (0, 10) >>= \n -> replicateM n arbitrary)
instance Arbitrary Passphrase where
    arbitrary = Passphrase . B.pack <$> (choose (0, 23) >>= \n -> replicateM n arbitrary)
instance Arbitrary Seed where
    arbitrary = Seed . B.pack <$> replicateM 32 arbitrary
instance Arbitrary ValidSeed where
    arbitrary = ValidSeed <$>
        (arbitrary `suchThat` \(Seed seed) -> case seedToSecret seed of
                                                CryptoPassed _ -> True
                                                _              -> False)

testEdwards25519 =
    [ testProperty "add" $ \(Ed _ a) (Ed _ b) -> (ltc a .+ ltc b) == ltc (Edwards25519.scalarAdd a b)
    ]
  where
    (.+) = Edwards25519.pointAdd
    ltc = Edwards25519.scalarToPoint

testPointAdd =
    [ testProperty "add" $ \(Ed _ a) (Ed _ b) ->
        let pa = Edwards25519.scalarToPoint a
            pb = Edwards25519.scalarToPoint b
            pc = Edwards25519.pointAdd pa pb
            pa' = pointToPublic pa
            pb' = pointToPublic pb
            pc' = EdVariant.publicAdd pa' pb'
         in Edwards25519.unPointCompressed pc === B.convert pc'
    ]

{-
testHdDerivation =
    [ testProperty "pub . sec-derivation = pub-derivation . pub" normalDerive
    , testProperty "verify (pub . pub-derive) (sign . sec-derivation)" verifyDerive
    ]
  where
    dummyChainCode = B.replicate 32 38
    dummyMsg = B.pack [1,2,3,4,5,6,7]

    normalDerive (Ed _ s) n =
        let pubKey = Edwards25519.scalarToPoint s
            prv = either error id $ xprv (Edwards25519.unScalar s `B.append` Edwards25519.unPointCompressed pubKey `B.append` dummyChainCode)
            pub = toXPub prv
            cPrv = deriveXPrv noPassphrase prv n
            cPub = deriveXPub pub n
         in unXPub (toXPub cPrv) === unXPub cPub

    verifyDerive (Ed _ s) n =
        let pubKey = Edwards25519.scalarToPoint s
            prv = either error id $ xprv (Edwards25519.unScalar s `B.append` Edwards25519.unPointCompressed pubKey `B.append` dummyChainCode)
            pub = toXPub prv
            cPrv = deriveXPrv noPassphrase prv n
            cPub = deriveXPub pub n
         in verify cPub dummyMsg (sign noPassphrase cPrv dummyMsg)
-}

testEncrypted =
    [ testProperty "pub(sec) = pub(encrypted(no-pass, sec))" (pubEq noPassphrase)
    , testProperty "pub(sec) = pub(encrypted(dummy, sec))" (pubEq dummyPassphrase)
    , testProperty "pub(sec) = pub(encrypted(no-pass, sec))" (pubEqValid noPassphrase)
    , testProperty "pub(sec) = pub(encrypted(dummy, sec))" (pubEqValid dummyPassphrase)
    , testProperty "sign(sec, msg) = sign(encrypted(no-pass, sec), msg)" (signEq noPassphrase)
    , testProperty "sign(sec, msg) = sign(encrypted(dummy, sec), msg)" (signEq dummyPassphrase)
    , testProperty "n <= 0x80000000 => pub(derive(sec, n)) = derive-public(pub(sec), n) [chaincode]" (deriveNormalChainCode noPassphrase)
    , testProperty "n <= 0x80000000 => pub(derive(sec, n)) = derive-public(pub(sec), n) [publickey]" (deriveNormalPublicKey dummyPassphrase)
    {-
    , testProperty "derive-hard(sec, n) = derive-hard(encrypted(no-pass, sec), n)" (deriveEq True noPassphrase)
    , testProperty "derive-hard(sec, n) = derive-hard(encrypted(dummy, sec), n)" (deriveEq True dummyPassphrase)
    , testProperty "derive-norm(sec, n) = derive-norm(encrypted(no-pass, sec), n)" (deriveEq False noPassphrase)
    , testProperty "derive-norm(sec, n) = derive-norm(encrypted(dummy, sec), n)" (deriveEq False dummyPassphrase)
    -}
    ]
  where
    dummyChainCode = B.replicate 32 38
    pubEq pass (Seed s) =
        let a    = seedToSecret s
            pub1 = EdVariant.toPublic <$> a
            ekey = encryptedCreate s pass dummyChainCode
         in (B.convert <$> pub1) === (encryptedPublic <$> ekey)
    pubEqValid pass (ValidSeed (Seed s)) =
        case (seedToSecret s, encryptedCreate s pass dummyChainCode) of
            (CryptoPassed a, CryptoPassed ekey) ->
                let pub1 = EdVariant.toPublic a
                 in B.convert pub1 === encryptedPublic ekey
            _ -> error "valid seed got a invalid result"

    signEq pass (ValidSeed (Seed s)) (Message msg) =
        case (seedToSecret s, encryptedCreate s pass dummyChainCode) of
            (CryptoPassed a, CryptoPassed ekey) ->
                let pub1 = EdVariant.toPublic a
                    sig1 = EdVariant.sign a dummyChainCode pub1 msg
                    (Signature sig2) = encryptedSign ekey pass msg
                 in B.convert sig1 === sig2
            _ -> error "valid seed got a invalid result"
    deriveNormalPublicKey pass (ValidSeed (Seed s)) nRaw =
        let ekey = throwCryptoError $ encryptedCreate s pass dummyChainCode
            ckey = encryptedDerivePrivate ekey pass n
            (expectedPubkey, expectedChainCode) = encryptedDerivePublic (encryptedPublic ekey, encryptedChainCode ekey) n
         in encryptedPublic ckey === expectedPubkey
      where n = nRaw `mod` 0x80000000
    deriveNormalChainCode pass (ValidSeed (Seed s)) nRaw =
        let ekey = throwCryptoError $ encryptedCreate s pass dummyChainCode
            ckey = encryptedDerivePrivate ekey pass n
            (expectedPubkey, expectedChainCode) = encryptedDerivePublic (encryptedPublic ekey, encryptedChainCode ekey) n
         in encryptedChainCode ckey === expectedChainCode
      where n = nRaw `mod` 0x80000000
            {-
    deriveEq True pass (Seed s) n =
        let a     = scalarToSecret s
            xprv1 = flip PureWallet.XPrv (ChainCode dummyChainCode) <$> s
            cprv1 = PureWallet.deriveXPrvHardened xprv1 n
            xprv2 = encryptedCreate s pass dummyChainCode
            cprv2 = encryptedDeriveHardened xprv2 pass n
         in PureWallet.xprvPub cprv1 === (encryptedPublic <$> cprv2)
    deriveEq False pass (Seed s) n =
        let a     = scalarToSecret s
            xprv1 = PureWallet.XPrv s (ChainCode dummyChainCode)
            cprv1 = PureWallet.deriveXPrv xprv1 n
            xprv2 = encryptedCreate s pass dummyChainCode
            cprv2 = encryptedDeriveNormal xprv2 pass n
         in PureWallet.xprvPub cprv1 === encryptedPublic cprv2
         -}

testVariant =
    [ testProperty "public-key" testPublicKey
    , testProperty "signature" testSignature
    , testProperty "scalar-add" testScalarAdd
    -- , testProperty "point-add" testPointAdd
    ]
  where
    testPublicKey (Ed _ a) =
        let pub1 = Edwards25519.scalarToPoint a
            pub2 = EdVariant.toPublic (scalarToSecret a)
         in pub1 `pointEqPublic` pub2
    testSignature (Ed _ a) (Salt salt) (Message msg) =
        let -- pub = Edwards25519.unPointCompressed $ Edwards25519.scalarToPoint a
            sec = scalarToSecret a
            sig1 = Edwards25519.sign a salt msg
            sig2 = EdVariant.sign sec salt (EdVariant.toPublic sec) msg
         in sig1 `signatureEqSig` sig2
    testScalarAdd (Ed _ a) (Ed _ b) =
        let r1 = Edwards25519.scalarAdd a b
            r2 = EdVariant.secretAdd (scalarToSecret a) (scalarToSecret b)
         in r1 `scalarEqSecret` r2
    testPointAdd (Ed _ a) (Ed _ b) =
        let p = Edwards25519.scalarToPoint a
            q = Edwards25519.scalarToPoint b
            p' = EdVariant.toPublic $ scalarToSecret a
            q' = EdVariant.toPublic $ scalarToSecret b
         in Edwards25519.pointAdd p q `pointEqPublic` EdVariant.publicAdd p' q'

    signatureEqSig :: Edwards25519.Signature -> EdVariant.Signature -> Property
    signatureEqSig sig sig2 = Edwards25519.unSignature sig === B.convert sig2

    pointEqPublic :: Edwards25519.PointCompressed -> EdVariant.PublicKey -> Property
    pointEqPublic pub (EdVariant.PublicKey pub2) = Edwards25519.unPointCompressed pub === B.convert pub2

    scalarEqSecret :: Edwards25519.Scalar -> EdVariant.SecretKey -> Property
    scalarEqSecret s sec = Edwards25519.unScalar s === B.convert sec

pointToPublic :: Edwards25519.PointCompressed -> EdVariant.PublicKey
pointToPublic = throwCryptoError . EdVariant.publicKey . Edwards25519.unPointCompressed

scalarToSecret :: Edwards25519.Scalar -> EdVariant.SecretKey
scalarToSecret = throwCryptoError . EdVariant.secretKey . Edwards25519.unScalar

testChangePassphrase =
    [ testProperty "change-passphrase-publickey-stable" pubEq
    , testProperty "normal-derive-key-different-passphrase-stable" deriveNormalEq
    , testProperty "hardened-derive-key-different-passphrase-stable" deriveHardenedEq
    ]
  where
    pubEq (ValidSeed (Seed s)) (Passphrase p1) (Passphrase p2) =
        let xprv1 = throwCryptoError $ encryptedCreate s p1 dummyChainCode
            xprv2 = encryptedChangePass p1 p2 xprv1
         in encryptedPublic xprv1 === encryptedPublic xprv2

    deriveNormalEq (ValidSeed (Seed s)) (Passphrase p1) (Passphrase p2) n =
        let xprv1 = throwCryptoError $ encryptedCreate s p1 dummyChainCode
            xprv2 = encryptedChangePass p1 p2 xprv1
            cPrv1 = encryptedDerivePrivate xprv1 p1 (toNormal n)
            cPrv2 = encryptedDerivePrivate xprv2 p2 (toNormal n)
         in encryptedPublic cPrv1 === encryptedPublic cPrv2

    deriveHardenedEq (ValidSeed (Seed s)) (Passphrase p1) (Passphrase p2) n =
        let xprv1 = throwCryptoError $ encryptedCreate s p1 dummyChainCode
            xprv2 = encryptedChangePass p1 p2 xprv1
            cPrv1 = encryptedDerivePrivate xprv1 p1 (toHardened n)
            cPrv2 = encryptedDerivePrivate xprv2 p2 (toHardened n)
         in encryptedPublic cPrv1 === encryptedPublic cPrv2

    dummyChainCode = B.replicate 32 38

    toHardened, toNormal :: Word32 -> Word32
    toHardened n = setBit n 31
    toNormal   n = clearBit n 31

seedToSecret :: B.ByteString -> CryptoFailable EdVariant.SecretKey
seedToSecret = EdVariant.secretKey

main :: IO ()
main = defaultMain $ testGroup "cryptokami-crypto"
    [ testGroup "edwards25519-arithmetic" testEdwards25519
    , testGroup "point-addition" testPointAdd
    , testGroup "encrypted" testEncrypted
    , testGroup "change-pass" testChangePassphrase
    ]
    {-
    , testGroup "edwards25519-ed25519variant" testVariant
    , testGroup "hd-derivation" testHdDerivation
    ]
    -}
