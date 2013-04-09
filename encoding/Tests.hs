import Test.QuickCheck
import Test.Framework(defaultMain, testGroup)
import Test.Framework.Providers.QuickCheck2(testProperty)

import Text.Printf

import Control.Applicative
import Data.ASN1.Get (runGet, Result(..))
import Data.ASN1.BitArray
import Data.ASN1.Stream
import Data.ASN1.Prim
import Data.ASN1.Serialize
import Data.ASN1.BinaryEncoding.Parse
import Data.ASN1.BinaryEncoding.Writer
import Data.ASN1.BinaryEncoding
import Data.ASN1.Encoding
import Data.ASN1.Types
import Data.ASN1.Types.Lowlevel
import Data.ASN1.OID

import Data.Time.Clock
import Data.Time.Calendar
import Data.Time.LocalTime

import Data.Word

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.Text.Lazy as T

import Control.Monad
import Control.Monad.Identity
import System.IO

instance Arbitrary ASN1Class where
        arbitrary = elements [ Universal, Application, Context, Private ]

instance Arbitrary ASN1Length where
        arbitrary = do
                c <- choose (0,2) :: Gen Int
                case c of
                        0 -> liftM LenShort (choose (0,0x79))
                        1 -> do
                                nb <- choose (0x80,0x1000)
                                return $ mkSmallestLength nb
                        _ -> return LenIndefinite
                where
                        nbBytes nb = if nb > 255 then 1 + nbBytes (nb `div` 256) else 1

arbitraryDefiniteLength :: Gen ASN1Length
arbitraryDefiniteLength = arbitrary `suchThat` (\l -> l /= LenIndefinite)

arbitraryTag :: Gen ASN1Tag
arbitraryTag = choose(1,10000)

instance Arbitrary ASN1Header where
        arbitrary = liftM4 ASN1Header arbitrary arbitraryTag arbitrary arbitrary

arbitraryEvents :: Gen ASN1Events
arbitraryEvents = do
        hdr@(ASN1Header _ _ _ len) <- liftM4 ASN1Header arbitrary arbitraryTag (return False) arbitraryDefiniteLength
        let blen = case len of
                LenLong _ x -> x
                LenShort x  -> x
                _           -> 0
        pr <- liftM Primitive (arbitraryBSsized blen)
        return (ASN1Events [Header hdr, pr])

newtype ASN1Events = ASN1Events [ASN1Event]

instance Show ASN1Events where
        show (ASN1Events x) = show x

instance Arbitrary ASN1Events where
        arbitrary = arbitraryEvents


arbitraryOID :: Gen OID
arbitraryOID = do
        i1  <- choose (0,2) :: Gen Integer
        i2  <- choose (0,39) :: Gen Integer
        ran <- choose (0,30) :: Gen Int
        l   <- replicateM ran (suchThat arbitrary (\i -> i > 0))
        return $ (i1:i2:l)

arbitraryBSsized :: Int -> Gen B.ByteString
arbitraryBSsized len = do
        ws <- replicateM len (choose (0, 255) :: Gen Int)
        return $ B.pack $ map fromIntegral ws

instance Arbitrary B.ByteString where
        arbitrary = do
                len <- choose (0, 529) :: Gen Int
                arbitraryBSsized len

instance Arbitrary T.Text where
        arbitrary = do
                len <- choose (0, 529) :: Gen Int
                ws <- replicateM len arbitrary
                return $ T.pack ws

instance Arbitrary BitArray where
        arbitrary = do
                bs <- arbitrary
                --w  <- choose (0,7) :: Gen Int
                return $ toBitArray bs 0

instance Arbitrary Day where
    arbitrary = do
        y <- choose (1951, 2050)
        m <- choose (0, 11)
        d <- choose (0, 31)
        return $ fromGregorian y m d

instance Arbitrary DiffTime where
    arbitrary = do
        h <- choose (0, 23)
        mi <- choose (0, 59)
        se <- choose (0, 59)
        return $ secondsToDiffTime (h*3600+mi*60+se)

instance Arbitrary UTCTime where
    arbitrary = UTCTime <$> arbitrary <*> arbitrary

instance Arbitrary TimeZone where
    arbitrary = return $ utc

instance Arbitrary ASN1TimeType where
    arbitrary = elements [TimeUTC, TimeGeneralized]

instance Arbitrary ASN1StringEncoding where
    arbitrary = elements [UTF8, Numeric, Printable, T61, VideoTex, IA5, Graphic, Visible, General, UTF32, BMP]

arbitraryPrintString = do
        let printableString = (['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9'] ++ " ()+,-./:=?")
        BC.pack <$> replicateM 21 (elements printableString)

arbitraryIA5String = do
        B.pack <$> replicateM 21 (elements $ map toEnum [0..127])

arbitraryString = do
    encoding <- arbitrary
    bs <- case encoding of
            UTF8      -> arbitraryPrintString
            Numeric   -> arbitraryPrintString
            Printable -> arbitraryPrintString
            T61       -> arbitraryPrintString
            VideoTex  -> arbitraryPrintString
            IA5       -> arbitraryIA5String
            Graphic   -> arbitraryPrintString
            Visible   -> arbitraryPrintString
            General   -> arbitraryPrintString
            UTF32     -> arbitraryPrintString
            BMP       -> arbitraryPrintString
    return $ ASN1String encoding bs

instance Arbitrary ASN1 where
        arbitrary = oneof
                [ liftM Boolean arbitrary
                , liftM IntVal arbitrary
                , liftM BitString arbitrary
                , liftM OctetString arbitrary
                , return Null
                , liftM OID arbitraryOID
                --, Real Double
                -- , return Enumerated
                , arbitraryString
                , ASN1Time <$> arbitrary <*> arbitrary <*> arbitrary
                ]

newtype ASN1s = ASN1s [ASN1]

instance Show ASN1s where
        show (ASN1s x) = show x

instance Arbitrary ASN1s where
        arbitrary = do
                x <- choose (0,5) :: Gen Int
                z <- case x of
                        4 -> makeList Sequence
                        3 -> makeList Set
                        _ -> resize 2 $ listOf1 arbitrary
                return $ ASN1s z
                where
                        makeList str = do
                                (ASN1s l) <- arbitrary
                                return ([Start str] ++ l ++ [End str])

prop_header_marshalling_id :: ASN1Header -> Bool
prop_header_marshalling_id v = (ofDone $ runGet getHeader $ putHeader v) == Right v
    where ofDone (Done r _ _) = Right r
          ofDone _            = Left "not done"

prop_event_marshalling_id :: ASN1Events -> Bool
prop_event_marshalling_id (ASN1Events e) = (parseLBS $ toLazyByteString e) == Right e

prop_asn1_der_marshalling_id v = (decodeASN1 DER . encodeASN1 DER) v `assertEq` Right v
    where assertEq got expected
                 | got /= expected = error ("got: " ++ show got ++ " expected: " ++ show expected)
                 | otherwise       = True

marshallingTests = testGroup "Marshalling"
    [ testProperty "Header" prop_header_marshalling_id
    , testProperty "Event"  prop_event_marshalling_id
    , testProperty "DER"    prop_asn1_der_marshalling_id
    ]

main = defaultMain [marshallingTests]
