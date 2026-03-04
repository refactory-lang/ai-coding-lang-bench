module Main where

import System.Environment (getArgs)
import System.Directory (doesDirectoryExist, doesFileExist, createDirectoryIfMissing)
import System.Exit (exitFailure)
import Data.Word (Word64)
import Data.Bits (xor)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as C8
import Data.List (sort, isPrefixOf)
import Numeric (showHex)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Control.Monad (when)

miniHash :: BS.ByteString -> String
miniHash bs = replicate (16 - length hex) '0' ++ hex
  where
    h = BS.foldl' step (1469598103934665603 :: Word64) bs
    step acc b = (acc `xor` fromIntegral b) * 1099511628211
    hex = showHex h ""

readStrict :: FilePath -> IO String
readStrict p = C8.unpack <$> BS.readFile p

main :: IO ()
main = do
    args <- getArgs
    case args of
        ["init"] -> cmdInit
        ["add", file] -> cmdAdd file
        ["commit", "-m", msg] -> cmdCommit msg
        ["log"] -> cmdLog
        _ -> putStrLn "Unknown command" >> exitFailure

cmdInit :: IO ()
cmdInit = do
    exists <- doesDirectoryExist ".minigit"
    if exists
        then putStrLn "Repository already initialized"
        else do
            createDirectoryIfMissing True ".minigit/objects"
            createDirectoryIfMissing True ".minigit/commits"
            writeFile ".minigit/index" ""
            writeFile ".minigit/HEAD" ""

cmdAdd :: String -> IO ()
cmdAdd filename = do
    exists <- doesFileExist filename
    if not exists
        then putStrLn "File not found" >> exitFailure
        else do
            content <- BS.readFile filename
            let hash = miniHash content
            BS.writeFile (".minigit/objects/" ++ hash) content
            idxStr <- readStrict ".minigit/index"
            let entries = filter (not . null) (lines idxStr)
            when (filename `notElem` entries) $
                writeFile ".minigit/index" (unlines (entries ++ [filename]))

cmdCommit :: String -> IO ()
cmdCommit message = do
    idxStr <- readStrict ".minigit/index"
    let entries = filter (not . null) (lines idxStr)
    if null entries
        then putStrLn "Nothing to commit" >> exitFailure
        else do
            headStr <- filter (\c -> c /= '\n' && c /= '\r') <$> readStrict ".minigit/HEAD"
            let parent = if null headStr then "NONE" else headStr
            t <- getPOSIXTime
            let timestamp = show (round t :: Integer)
                sortedFiles = sort entries
            fileLines <- mapM (\f -> do
                content <- BS.readFile f
                return (f ++ " " ++ miniHash content)) sortedFiles
            let commitStr = unlines $
                    [ "parent: " ++ parent
                    , "timestamp: " ++ timestamp
                    , "message: " ++ message
                    , "files:" ] ++ fileLines
                commitBS = C8.pack commitStr
                commitHash = miniHash commitBS
            C8.writeFile (".minigit/commits/" ++ commitHash) commitBS
            writeFile ".minigit/HEAD" commitHash
            writeFile ".minigit/index" ""
            putStrLn ("Committed " ++ commitHash)

cmdLog :: IO ()
cmdLog = do
    headStr <- filter (\c -> c /= '\n' && c /= '\r') <$> readStrict ".minigit/HEAD"
    if null headStr
        then putStrLn "No commits"
        else printLog headStr
  where
    printLog hash = do
        content <- readStrict (".minigit/commits/" ++ hash)
        let ls = lines content
            getField prefix = drop (length prefix) $ head $ filter (isPrefixOf prefix) ls
            parent = getField "parent: "
            timestamp = getField "timestamp: "
            msg = getField "message: "
        putStrLn ("commit " ++ hash)
        putStrLn ("Date: " ++ timestamp)
        putStrLn ("Message: " ++ msg)
        when (parent /= "NONE") $ do
            putStrLn ""
            printLog parent
