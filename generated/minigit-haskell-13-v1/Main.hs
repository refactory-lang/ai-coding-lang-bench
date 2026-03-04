module Main where

import Data.Bits (xor)
import Data.Char (ord)
import Data.List (sort, nub, intercalate)
import Data.Word (Word8, Word64)
import System.Directory (createDirectoryIfMissing, doesFileExist, doesDirectoryExist)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import qualified Data.ByteString as BS
import Data.Time.Clock.POSIX (getPOSIXTime)
import Numeric (showHex)

miniHash :: BS.ByteString -> String
miniHash bs = padLeft 16 '0' $ showHex (BS.foldl' step 1469598103934665603 bs) ""
  where
    step :: Word64 -> Word8 -> Word64
    step h b = (h `xor` fromIntegral b) * 1099511628211
    padLeft n c s = replicate (n - length s) c ++ s

main :: IO ()
main = do
    args <- getArgs
    case args of
        ["init"] -> cmdInit
        ["add", file] -> cmdAdd file
        ["commit", "-m", msg] -> cmdCommit msg
        ["log"] -> cmdLog
        _ -> do
            hPutStrLn stderr "Usage: minigit <command>"
            exitFailure

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
cmdAdd file = do
    exists <- doesFileExist file
    if not exists
        then do
            putStrLn "File not found"
            exitFailure
        else do
            content <- BS.readFile file
            let hash = miniHash content
            BS.writeFile (".minigit/objects/" ++ hash) content
            -- Add to index if not already present
            idx <- readFile ".minigit/index"
            let entries = if null idx then [] else lines idx
            if file `elem` entries
                then return ()
                else writeFile ".minigit/index" (unlines (entries ++ [file]))

cmdCommit :: String -> IO ()
cmdCommit msg = do
    idx <- readFile ".minigit/index"
    let entries = filter (not . null) (lines idx)
    if null entries
        then do
            putStrLn "Nothing to commit"
            exitFailure
        else do
            headContent <- readFile ".minigit/HEAD"
            let parent = if null headContent then "NONE" else headContent
            timestamp <- fmap (show . (floor :: Double -> Integer) . realToFrac) getPOSIXTime
            -- Build file entries: for each file, read and hash
            let sortedFiles = sort entries
            fileLines <- mapM (\f -> do
                content <- BS.readFile f
                let h = miniHash content
                return (f ++ " " ++ h)
                ) sortedFiles
            let commitContent = "parent: " ++ parent ++ "\n"
                             ++ "timestamp: " ++ timestamp ++ "\n"
                             ++ "message: " ++ msg ++ "\n"
                             ++ "files:\n"
                             ++ unlines fileLines
            let commitHash = miniHash (stringToBS commitContent)
            writeFile (".minigit/commits/" ++ commitHash) commitContent
            writeFile ".minigit/HEAD" commitHash
            writeFile ".minigit/index" ""
            putStrLn ("Committed " ++ commitHash)

cmdLog :: IO ()
cmdLog = do
    headContent <- readFile ".minigit/HEAD"
    if null headContent
        then putStrLn "No commits"
        else printLog headContent

printLog :: String -> IO ()
printLog hash = do
    let path = ".minigit/commits/" ++ hash
    content <- readFile path
    let ls = lines content
        parentLine = head ls
        timestampLine = ls !! 1
        messageLine = ls !! 2
        parent = drop 8 parentLine  -- "parent: " is 8 chars
        timestamp = drop 11 timestampLine  -- "timestamp: " is 11 chars
        message = drop 9 messageLine  -- "message: " is 9 chars
    putStrLn ("commit " ++ hash)
    putStrLn ("Date: " ++ timestamp)
    putStrLn ("Message: " ++ message)
    if parent /= "NONE"
        then do
            putStrLn ""
            printLog parent
        else return ()

stringToBS :: String -> BS.ByteString
stringToBS = BS.pack . map (fromIntegral . ord)
