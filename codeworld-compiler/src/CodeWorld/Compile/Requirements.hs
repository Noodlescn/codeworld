{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{-
  Copyright 2018 The CodeWorld Authors. All rights reserved.

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
-}

module CodeWorld.Compile.Requirements (checkRequirements) where

import CodeWorld.Compile.Framework
import CodeWorld.Compile.Requirements.Eval
import CodeWorld.Compile.Requirements.Language
import Codec.Compression.Zlib
import Control.Exception
import Control.Monad
import Data.Array
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as B (toStrict, fromStrict)
import qualified Data.ByteString.Base64 as B64
import Data.Char
import Data.Either
import Data.Monoid
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8, decodeUtf8)
import Language.Haskell.Exts
import System.IO.Unsafe
import Text.Regex.TDFA
import Text.Regex.TDFA.Text

checkRequirements :: MonadCompile m => m ()
checkRequirements = do
    sources <- extractRequirementsSource
    reqs <- extractRequirements sources
    when (not (null reqs)) $ do
        m <- getParsedCode
        let obfuscated = T.unpack (obfuscate (map snd sources))
        addDiagnostics
            [ (noSrcSpan, Info,
               "                    :: REQUIREMENTS ::\n" ++
               "Obfuscated:\n\n    XREQUIRES" ++ obfuscated ++ "\n\n" ++
               concatMap (handleRequirement m) reqs ++
               "                  :: END REQUIREMENTS ::\n")
            ]

plainPattern :: Text
plainPattern = "{-+[[:space:]]*REQUIRES\\b((\n|[^-]|-[^}])*)-}"

codedPattern :: Text
codedPattern = "{-+[[:space:]]*XREQUIRES\\b((\n|[^-]|-[^}])*)-}"

extractRequirementsSource :: MonadCompile m => m [(SrcSpanInfo, Text)]
extractRequirementsSource = do
    src <- decodeUtf8 <$> getSourceCode
    let plain = extractSubmatches plainPattern src
    let blocks = map (fmap deobfuscate) (extractSubmatches codedPattern src)
    addDiagnostics [ (spn, Warning, "Coded requirements were corrupted.")
                     | (spn, Nothing) <- blocks ]
    let coded = [ (spn, rule) | (spn, Just block) <- blocks, rule <- block ]
    return (plain ++ coded)

extractSubmatches :: Text -> Text -> [(SrcSpanInfo, Text)]
extractSubmatches pattern src =
    [ (srcSpanFor src off len, T.take len (T.drop off src))
      | matchArray :: MatchArray <- src =~ pattern
      , rangeSize (bounds matchArray) > 1
      , let (off, len) = matchArray ! 1 ]

extractRequirements :: MonadCompile m => [(SrcSpanInfo, Text)] -> m [Requirement]
extractRequirements sources = do
    addDiagnostics diags
    return reqs
  where results = [ parseRequirement ln col source
                    | (SrcSpanInfo spn _, source) <- sources
                    , let ln = srcSpanStartLine spn
                    , let col = srcSpanStartColumn spn ]
        diags = [ format err | Left err <- results ]
        reqs =  [ req | Right req <- results ]
        format err = (noSrcSpan, Warning,
                      "The requirement could not be understood:\n" ++ err)

handleRequirement :: ParsedCode -> Requirement -> String
handleRequirement m r =
    label ++ desc ++ "\n" ++ concat [ "      " ++ msg ++ "\n" | msg <- msgs ]
  where (desc, success, msgs) = evalRequirement r m
        label | success   = "[Y] "
              | otherwise = "[N] "

obfuscate :: [Text] -> Text
obfuscate = wrapWithPrefix 60 "\n    " . decodeUtf8 . B64.encode .
            B.toStrict . compress . B.fromStrict . encodeUtf8 . T.pack .
            show . map T.unpack

deobfuscate :: Text -> Maybe [Text]
deobfuscate = fmap (map T.pack . read . T.unpack . decodeUtf8) .
              partialToMaybe . B.toStrict . decompress . B.fromStrict .
              B64.decodeLenient . encodeUtf8 . T.filter (not . isSpace)

wrapWithPrefix :: Int -> Text -> Text -> Text
wrapWithPrefix n pre txt = T.concat (parts txt)
  where parts t | T.length t < n = [pre <> t]
                | otherwise = let (a, b) = T.splitAt n t
                              in pre <> a : parts b

partialToMaybe :: a -> Maybe a
partialToMaybe = (eitherToMaybe :: Either SomeException a -> Maybe a) .
                 unsafePerformIO . try . evaluate

eitherToMaybe :: Either a b -> Maybe b
eitherToMaybe = either (const Nothing) Just
