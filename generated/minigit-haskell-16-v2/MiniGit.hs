module Main where

import Data.Bits (xor)
import Data.Char (ord)
import Data.List (sort, isPrefixOf)
import Data.Word (Word8, Word64)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist)
import System.Environment (getArgs)
import System.Exit (exitFailure)
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
        ["init"]                    -> cmdInit
        ["add", file]               -> cmdAdd file
        ["commit", "-m", msg]       -> cmdCommit msg
        ["status"]                  -> cmdStatus
        ["log"]                     -> cmdLog
        ["diff", c1, c2]            -> cmdDiff c1 c2
        ["checkout", hash]          -> cmdCheckout hash
        ["reset", hash]             -> cmdReset hash
        ["rm", file]                -> cmdRm file
        ["show", hash]              -> cmdShow hash
        _                           -> do
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

cmdStatus :: IO ()
cmdStatus = do
    idx <- readFile indexFile
    let entries = filter (not . null) (lines idx)
    putStrLn "Staged files:"
    if null entries
        then putStrLn "(none)"
        else mapM_ putStrLn entries

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
    let timestamp = drop 11 (ls !! 1)
    let message   = drop 9  (ls !! 2)
    putStrLn ("commit " ++ hash)
    putStrLn ("Date: " ++ timestamp)
    putStrLn ("Message: " ++ message)
    let parent = drop 8 (head ls)
    if parent == "NONE"
        then return ()
        else do
            putStrLn ""
            printLog parent

-- Parse the files section of a commit, returning [(filename, blobhash)]
parseCommitFiles :: String -> [(String, String)]
parseCommitFiles content =
    let ls = lines content
        afterFiles = drop 1 $ dropWhile (/= "files:") ls
    in map parseFileLine $ filter (not . null) afterFiles
  where
    parseFileLine line =
        let (fname, rest) = break (== ' ') line
        in (fname, drop 1 rest)

cmdDiff :: String -> String -> IO ()
cmdDiff c1 c2 = do
    e1 <- doesFileExist (commitsDir ++ "/" ++ c1)
    e2 <- doesFileExist (commitsDir ++ "/" ++ c2)
    if not (e1 && e2)
        then do
            putStrLn "Invalid commit"
            exitFailure
        else do
            content1 <- readFile (commitsDir ++ "/" ++ c1)
            content2 <- readFile (commitsDir ++ "/" ++ c2)
            let files1 = parseCommitFiles content1
            let files2 = parseCommitFiles content2
            let allFiles = sort $ unique $ map fst files1 ++ map fst files2
            mapM_ (\f -> do
                let h1 = lookup f files1
                let h2 = lookup f files2
                case (h1, h2) of
                    (Nothing, Just _)  -> putStrLn ("Added: " ++ f)
                    (Just _, Nothing)  -> putStrLn ("Removed: " ++ f)
                    (Just a, Just b)   -> if a /= b
                                            then putStrLn ("Modified: " ++ f)
                                            else return ()
                    _                  -> return ()
                ) allFiles

unique :: Eq a => [a] -> [a]
unique [] = []
unique (x:xs) = x : unique (filter (/= x) xs)

cmdCheckout :: String -> IO ()
cmdCheckout hash = do
    exists <- doesFileExist (commitsDir ++ "/" ++ hash)
    if not exists
        then do
            putStrLn "Invalid commit"
            exitFailure
        else do
            content <- readFile (commitsDir ++ "/" ++ hash)
            let files = parseCommitFiles content
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
    idx <- fmap BS.unpack (BS.readFile indexFile)
    let idxStr = map (toEnum . fromIntegral) idx :: String
    let entries = filter (not . null) (lines idxStr)
    if file `elem` entries
        then do
            let newEntries = filter (/= file) entries
            writeFile indexFile (unlines newEntries)
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
            content <- readFile (commitsDir ++ "/" ++ hash)
            let ls = lines content
            let timestamp = drop 11 (ls !! 1)
            let message   = drop 9  (ls !! 2)
            let files = sort $ parseCommitFiles content
            putStrLn ("commit " ++ hash)
            putStrLn ("Date: " ++ timestamp)
            putStrLn ("Message: " ++ message)
            putStrLn "Files:"
            mapM_ (\(f, h) -> putStrLn ("  " ++ f ++ " " ++ h)) files
