module Main where

import Data.Bits (xor)
import Data.Char (ord)
import Data.List (sort, intercalate, isPrefixOf)
import Data.Word (Word8, Word64)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist)
import System.Environment (getArgs)
import System.Exit (exitFailure, exitSuccess)
import System.IO (hPutStrLn, stderr)
import qualified Data.ByteString as BS
import Data.Time.Clock.POSIX (getPOSIXTime)
import Numeric (showHex)

miniHash :: BS.ByteString -> String
miniHash bs = pad 16 $ showHex result ""
  where
    result = BS.foldl' step 1469598103934665603 bs
    step :: Word64 -> Word8 -> Word64
    step h b = (h `xor` fromIntegral b) * 1099511628211

pad :: Int -> String -> String
pad n s = replicate (n - length s) '0' ++ s

minigitDir :: FilePath
minigitDir = ".minigit"

objectsDir, commitsDir, indexFile, headFile :: FilePath
objectsDir = minigitDir ++ "/objects"
commitsDir = minigitDir ++ "/commits"
indexFile  = minigitDir ++ "/index"
headFile   = minigitDir ++ "/HEAD"

main :: IO ()
main = do
    args <- getArgs
    case args of
        ["init"]              -> cmdInit
        ["add", file]         -> cmdAdd file
        ["commit", "-m", msg] -> cmdCommit msg
        ["log"]               -> cmdLog
        _                     -> do
            hPutStrLn stderr "Usage: minigit <command>"
            exitFailure

cmdInit :: IO ()
cmdInit = do
    exists <- doesDirectoryExist minigitDir
    if exists
        then putStrLn "Repository already initialized"
        else do
            createDirectoryIfMissing True objectsDir
            createDirectoryIfMissing True commitsDir
            writeFile indexFile ""
            writeFile headFile ""

cmdAdd :: FilePath -> IO ()
cmdAdd file = do
    exists <- doesFileExist file
    if not exists
        then do
            putStrLn "File not found"
            exitFailure
        else do
            content <- BS.readFile file
            let hash = miniHash content
            BS.writeFile (objectsDir ++ "/" ++ hash) content
            -- Add to index if not already present
            idx <- readFile indexFile
            let entries = if null idx then [] else lines idx
            if file `elem` entries
                then return ()
                else writeFile indexFile (idx ++ file ++ "\n")

cmdCommit :: String -> IO ()
cmdCommit msg = do
    idx <- readFile indexFile
    let entries = filter (not . null) (lines idx)
    if null entries
        then do
            putStrLn "Nothing to commit"
            exitFailure
        else do
            headContent <- readFile headFile
            let parent = if null headContent then "NONE" else headContent
            timestamp <- fmap (show . (floor :: Double -> Integer) . realToFrac) getPOSIXTime
            -- Build file list with hashes
            fileEntries <- mapM (\f -> do
                content <- BS.readFile f
                let h = miniHash content
                return (f, h)
                ) (sort entries)
            let fileLines = map (\(f, h) -> f ++ " " ++ h) fileEntries
            let commitContent = "parent: " ++ parent ++ "\n"
                             ++ "timestamp: " ++ timestamp ++ "\n"
                             ++ "message: " ++ msg ++ "\n"
                             ++ "files:\n"
                             ++ unlines fileLines
            let commitHash = miniHash (BS.pack (map (fromIntegral . ord) commitContent))
            writeFile (commitsDir ++ "/" ++ commitHash) commitContent
            writeFile headFile commitHash
            writeFile indexFile ""
            putStrLn ("Committed " ++ commitHash)

cmdLog :: IO ()
cmdLog = do
    headContent <- readFile headFile
    if null headContent
        then putStrLn "No commits"
        else printLog headContent

printLog :: String -> IO ()
printLog hash = do
    let commitPath = commitsDir ++ "/" ++ hash
    content <- readFile commitPath
    let ls = lines content
    let timestamp = drop 11 (ls !! 1)  -- "timestamp: "
    let message   = drop 9  (ls !! 2)  -- "message: "
    putStrLn ("commit " ++ hash)
    putStrLn ("Date: " ++ timestamp)
    putStrLn ("Message: " ++ message)
    let parentLine = head ls
    let parent = drop 8 parentLine  -- "parent: "
    if parent == "NONE"
        then return ()
        else do
            putStrLn ""
            printLog parent
