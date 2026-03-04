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
        ["status"]             -> cmdStatus
        ["log"]                -> cmdLog
        ["diff", c1, c2]       -> cmdDiff c1 c2
        ["checkout", hash]     -> cmdCheckout hash
        ["reset", hash]        -> cmdReset hash
        ["rm", file]           -> cmdRm file
        ["show", hash]         -> cmdShow hash
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
            idxBS <- BS.readFile indexFile
            let idx = map (toEnum . fromIntegral) (BS.unpack idxBS) :: String
            let entries = if null idx then [] else lines idx
            if file `elem` entries
                then return ()
                else writeFile indexFile (unlines (entries ++ [file]))

-- Strict string read to avoid lazy IO issues
readFileStrict :: FilePath -> IO String
readFileStrict path = do
    bs <- BS.readFile path
    return $ map (toEnum . fromIntegral) (BS.unpack bs)

-- Helper to read lines from index, filtering empty lines (strict to avoid lazy IO issues)
readIndex :: IO [String]
readIndex = do
    s <- readFileStrict indexFile
    return $ filter (not . null) (lines s)

cmdCommit :: String -> IO ()
cmdCommit msg = do
    entries <- readIndex
    if null entries
        then do
            putStrLn "Nothing to commit"
            exitFailure
        else do
            -- Get parent
            headContent <- readFileStrict headFile
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
    headContent <- readFileStrict headFile
    if null headContent
        then putStrLn "No commits"
        else printLog headContent

printLog :: String -> IO ()
printLog hash = do
    let commitPath = commitsDir ++ "/" ++ hash
    content <- readFileStrict commitPath
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

cmdStatus :: IO ()
cmdStatus = do
    entries <- readIndex
    putStrLn "Staged files:"
    if null entries
        then putStrLn "(none)"
        else mapM_ putStrLn entries

cmdDiff :: String -> String -> IO ()
cmdDiff c1 c2 = do
    exists1 <- doesFileExist (commitsDir ++ "/" ++ c1)
    exists2 <- doesFileExist (commitsDir ++ "/" ++ c2)
    if not exists1 || not exists2
        then do
            putStrLn "Invalid commit"
            exitFailure
        else do
            files1 <- parseCommitFiles c1
            files2 <- parseCommitFiles c2
            let allFiles = sort $ unique (map fst files1 ++ map fst files2)
            mapM_ (\f -> do
                let inC1 = lookup f files1
                let inC2 = lookup f files2
                case (inC1, inC2) of
                    (Nothing, Just _)  -> putStrLn ("Added: " ++ f)
                    (Just _, Nothing)  -> putStrLn ("Removed: " ++ f)
                    (Just h1, Just h2) -> if h1 /= h2
                                            then putStrLn ("Modified: " ++ f)
                                            else return ()
                    (Nothing, Nothing) -> return ()
                ) allFiles

unique :: Eq a => [a] -> [a]
unique [] = []
unique (x:xs) = x : unique (filter (/= x) xs)

parseCommitFiles :: String -> IO [(String, String)]
parseCommitFiles hash = do
    content <- readFileStrict (commitsDir ++ "/" ++ hash)
    let ls = lines content
    let afterFiles = drop 1 $ dropWhile (/= "files:") ls
    return $ map parseFileLine $ filter (not . null) afterFiles

parseFileLine :: String -> (String, String)
parseFileLine line =
    let (fname, rest) = break (== ' ') line
    in (fname, drop 1 rest)

cmdCheckout :: String -> IO ()
cmdCheckout hash = do
    exists <- doesFileExist (commitsDir ++ "/" ++ hash)
    if not exists
        then do
            putStrLn "Invalid commit"
            exitFailure
        else do
            files <- parseCommitFiles hash
            mapM_ (\(fname, blobHash) -> do
                blob <- BS.readFile (objectsDir ++ "/" ++ blobHash)
                BS.writeFile fname blob
                ) files
            writeFile headFile hash
            writeFile indexFile ""
            putStrLn ("Checked out " ++ hash)

cmdReset :: String -> IO ()
cmdReset hash = do
    exists <- doesFileExist (commitsDir ++ "/" ++ hash)
    if not exists
        then do
            putStrLn "Invalid commit"
            exitFailure
        else do
            writeFile headFile hash
            writeFile indexFile ""
            putStrLn ("Reset to " ++ hash)

cmdRm :: String -> IO ()
cmdRm file = do
    entries <- readIndex
    if file `elem` entries
        then writeFile indexFile (unlines (filter (/= file) entries))
        else do
            putStrLn "File not in index"
            exitFailure

cmdShow :: String -> IO ()
cmdShow hash = do
    exists <- doesFileExist (commitsDir ++ "/" ++ hash)
    if not exists
        then do
            putStrLn "Invalid commit"
            exitFailure
        else do
            content <- readFileStrict (commitsDir ++ "/" ++ hash)
            let ls = lines content
            let timestamp = extractField "timestamp: " ls
            let message   = extractField "message: " ls
            files <- parseCommitFiles hash
            putStrLn ("commit " ++ hash)
            putStrLn ("Date: " ++ timestamp)
            putStrLn ("Message: " ++ message)
            putStrLn "Files:"
            mapM_ (\(fname, blobHash) -> putStrLn ("  " ++ fname ++ " " ++ blobHash)) (sort files)
