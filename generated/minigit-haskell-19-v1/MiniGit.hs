module Main where

import Data.Bits (xor)
import Data.Char (toLower)
import Data.List (sort, nub, intercalate)
import Data.Word (Word8, Word64)
import System.Directory (createDirectoryIfMissing, doesFileExist, doesDirectoryExist, listDirectory)
import System.Environment (getArgs)
import System.Exit (exitFailure, exitSuccess)
import System.IO (hFlush, stdout)
import qualified Data.ByteString as BS
import Data.Time.Clock.POSIX (getPOSIXTime)
import Numeric (showHex)

miniHash :: BS.ByteString -> String
miniHash bs = padHex 16 $ showHex finalH ""
  where
    initialH :: Word64
    initialH = 1469598103934665603
    finalH = BS.foldl' step initialH bs
    step :: Word64 -> Word8 -> Word64
    step h b = (h `xor` fromIntegral b) * 1099511628211
    padHex n s = replicate (n - length s) '0' ++ map toLower s

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
            putStrLn "Usage: minigit <command>"
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
            -- Read current index and add if not present
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
            -- Get parent
            headContent <- readFile headFile
            let parent = if null headContent then "NONE" else headContent
            -- Get timestamp
            now <- getPOSIXTime
            let timestamp = show (floor now :: Integer)
            -- Build file list: for each file in index, get its blob hash
            let sortedFiles = sort entries
            fileLines <- mapM (\f -> do
                content <- BS.readFile f
                let hash = miniHash content
                return (f ++ " " ++ hash)
                ) sortedFiles
            -- Build commit content
            let commitContent = "parent: " ++ parent ++ "\n"
                             ++ "timestamp: " ++ timestamp ++ "\n"
                             ++ "message: " ++ msg ++ "\n"
                             ++ "files:\n"
                             ++ unlines fileLines
            -- Hash commit content
            let commitHash = miniHash (BS.pack (map (fromIntegral . fromEnum) commitContent))
            -- Write commit file
            writeFile (commitsDir ++ "/" ++ commitHash) commitContent
            -- Update HEAD
            writeFile headFile commitHash
            -- Clear index
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
    -- Parse timestamp and message
    let timestamp = drop 11 (ls !! 1)  -- "timestamp: <val>"
        message   = drop 9 (ls !! 2)   -- "message: <val>"
        parentRaw = drop 8 (ls !! 0)   -- "parent: <val>"
    putStrLn ("commit " ++ hash)
    putStrLn ("Date: " ++ timestamp)
    putStrLn ("Message: " ++ message)
    if parentRaw /= "NONE"
        then do
            putStrLn ""
            printLog parentRaw
        else return ()
