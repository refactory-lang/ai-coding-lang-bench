module Main where

import Data.Bits (xor)
import Data.Char (toLower)
import Data.List (sort, intercalate, isPrefixOf)
import Data.Word (Word64)
import qualified Data.ByteString as BS
import System.Directory
import System.Environment (getArgs)
import System.Exit (exitFailure, exitSuccess)
import System.IO (hPutStrLn, stderr)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Numeric (showHex)

-- MiniHash: FNV-1a variant, 64-bit, 16-char hex output
miniHash :: BS.ByteString -> String
miniHash bs = padHex 16 $ map toLower $ showHex result ""
  where
    initial :: Word64
    initial = 1469598103934665603
    step :: Word64 -> Word64 -> Word64
    step h b = (h `xor` b) * 1099511628211
    result = BS.foldl' (\h byte -> step h (fromIntegral byte)) initial bs

padHex :: Int -> String -> String
padHex n s = replicate (n - length s) '0' ++ s

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
        ["init"]               -> cmdInit
        ["add", file]          -> cmdAdd file
        ["commit", "-m", msg]  -> cmdCommit msg
        ["log"]                -> cmdLog
        _                      -> do
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
            let objPath = objectsDir ++ "/" ++ hash
            BS.writeFile objPath content
            -- Read current index and add file if not already present
            idx <- readFile indexFile
            let entries = if null idx then [] else lines idx
            if file `elem` entries
                then return ()
                else writeFile indexFile (unlines (entries ++ [file]))

-- Helper to read lines from index, filtering empty lines
readIndex :: IO [String]
readIndex = do
    content <- readFile indexFile
    return $ filter (not . null) (lines content)

cmdCommit :: String -> IO ()
cmdCommit msg = do
    entries <- readIndex
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

            -- Build file list: for each staged file, compute its current hash
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

            let commitHash = miniHash (strToBS commitContent)

            -- Write commit file
            writeFile (commitsDir ++ "/" ++ commitHash) commitContent

            -- Update HEAD
            writeFile headFile commitHash

            -- Clear index
            writeFile indexFile ""

            putStrLn ("Committed " ++ commitHash)

strToBS :: String -> BS.ByteString
strToBS = BS.pack . map (fromIntegral . fromEnum)

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
    let timestamp = extractField "timestamp: " ls
    let message   = extractField "message: " ls
    let parent    = extractField "parent: " ls
    putStrLn ("commit " ++ hash)
    putStrLn ("Date: " ++ timestamp)
    putStrLn ("Message: " ++ message)
    if parent /= "NONE"
        then do
            putStrLn ""
            printLog parent
        else return ()

extractField :: String -> [String] -> String
extractField prefix ls =
    case filter (isPrefixOf prefix) ls of
        (x:_) -> drop (length prefix) x
        []    -> ""
