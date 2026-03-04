module Main where

import Data.Bits (xor)
import Data.Char (ord)
import Data.List (sort, intercalate, isPrefixOf)
import Data.Word (Word64)
import System.Directory (createDirectoryIfMissing, doesFileExist, doesDirectoryExist, listDirectory)
import System.Environment (getArgs)
import System.Exit (exitFailure, exitSuccess)
import System.IO (hPutStrLn, stderr)
import qualified Data.ByteString as BS
import Data.Time.Clock.POSIX (getPOSIXTime)
import Numeric (showHex)

miniHash :: BS.ByteString -> String
miniHash bs = padLeft 16 '0' $ showHex final ""
  where
    initial :: Word64
    initial = 1469598103934665603
    step :: Word64 -> Word64 -> Word64
    step h b = (h `xor` b) * 1099511628211
    final = BS.foldl' (\h b -> step h (fromIntegral b)) initial bs

padLeft :: Int -> Char -> String -> String
padLeft n c s
  | length s >= n = s
  | otherwise = replicate (n - length s) c ++ s

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
        ["status"]            -> cmdStatus
        ["log"]               -> cmdLog
        ["diff", c1, c2]      -> cmdDiff c1 c2
        ["checkout", hash]    -> cmdCheckout hash
        ["reset", hash]       -> cmdReset hash
        ["rm", file]          -> cmdRm file
        ["show", hash]        -> cmdShow hash
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
            idxBytes <- BS.readFile indexFile
            let idx = bsToString idxBytes
            let entries = filter (not . null) (if null idx then [] else lines idx)
            if file `elem` entries
                then return ()
                else writeFile indexFile (idx ++ file ++ "\n")

cmdCommit :: String -> IO ()
cmdCommit msg = do
    idx <- readFileStrict indexFile
    let entries = filter (not . null) (lines idx)
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
            -- Build file entries: for each file, get its blob hash
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
            -- Hash the commit
            let commitHash = miniHash (BS.pack (map (fromIntegral . ord) commitContent))
            -- Write commit file
            writeFile (commitsDir ++ "/" ++ commitHash) commitContent
            -- Update HEAD
            writeFile headFile commitHash
            -- Clear index
            writeFile indexFile ""
            putStrLn ("Committed " ++ commitHash)

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
    let timestamp = drop (length "timestamp: ") (ls !! 1)
    let message   = drop (length "message: ")   (ls !! 2)
    let parentLine = ls !! 0
    let parent = drop (length "parent: ") parentLine
    putStrLn ("commit " ++ hash)
    putStrLn ("Date: " ++ timestamp)
    putStrLn ("Message: " ++ message)
    if parent /= "NONE"
        then do
            putStrLn ""
            printLog parent
        else return ()

cmdStatus :: IO ()
cmdStatus = do
    idx <- readFileStrict indexFile
    let entries = filter (not . null) (lines idx)
    putStrLn "Staged files:"
    if null entries
        then putStrLn "(none)"
        else mapM_ putStrLn entries

cmdDiff :: String -> String -> IO ()
cmdDiff c1 c2 = do
    e1 <- doesFileExist (commitsDir ++ "/" ++ c1)
    e2 <- doesFileExist (commitsDir ++ "/" ++ c2)
    if not (e1 && e2)
        then do
            putStrLn "Invalid commit"
            exitFailure
        else do
            files1 <- parseCommitFiles c1
            files2 <- parseCommitFiles c2
            let allFiles = sort $ unique (map fst files1 ++ map fst files2)
            mapM_ (\f -> do
                let h1 = lookup f files1
                let h2 = lookup f files2
                case (h1, h2) of
                    (Nothing, Just _)  -> putStrLn ("Added: " ++ f)
                    (Just _, Nothing)  -> putStrLn ("Removed: " ++ f)
                    (Just a, Just b)   -> if a /= b then putStrLn ("Modified: " ++ f) else return ()
                    _                  -> return ()
                ) allFiles

unique :: Eq a => [a] -> [a]
unique [] = []
unique (x:xs) = x : unique (filter (/= x) xs)

parseCommitFiles :: String -> IO [(String, String)]
parseCommitFiles hash = do
    content <- readFileStrict (commitsDir ++ "/" ++ hash)
    let ls = lines content
    let fileLines = drop 1 (dropWhile (/= "files:") ls)
    return $ map parseFileLine (filter (not . null) fileLines)

parseFileLine :: String -> (String, String)
parseFileLine line = case words line of
    [fname, fhash] -> (fname, fhash)
    _              -> ("", "")

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
                content <- BS.readFile (objectsDir ++ "/" ++ blobHash)
                BS.writeFile fname content
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
    idx <- readFileStrict indexFile
    let entries = filter (not . null) (lines idx)
    if file `elem` entries
        then do
            let newEntries = filter (/= file) entries
            writeFile indexFile (if null newEntries then "" else unlines newEntries)
        else do
            putStrLn "File not in index"
            exitFailure

bsToString :: BS.ByteString -> String
bsToString = map (toEnum . fromIntegral) . BS.unpack

readFileStrict :: FilePath -> IO String
readFileStrict path = do
    bs <- BS.readFile path
    return (bsToString bs)

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
            let timestamp = drop (length "timestamp: ") (ls !! 1)
            let message   = drop (length "message: ")   (ls !! 2)
            let fileLines = drop 1 (dropWhile (/= "files:") ls)
            let sortedFiles = sort (filter (not . null) fileLines)
            putStrLn ("commit " ++ hash)
            putStrLn ("Date: " ++ timestamp)
            putStrLn ("Message: " ++ message)
            putStrLn "Files:"
            mapM_ (\f -> putStrLn ("  " ++ f)) sortedFiles
