module Main where

import Data.Bits (xor)
import Data.Char (toLower)
import Data.List (sort, intercalate, isPrefixOf)
import Data.Word (Word8, Word64)
import System.Directory (createDirectoryIfMissing, doesFileExist, doesDirectoryExist)
import System.Environment (getArgs)
import System.Exit (exitFailure)
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
            now <- getPOSIXTime
            let timestamp = show (floor now :: Integer)
            let sortedFiles = sort entries
            fileLines <- mapM (\f -> do
                content <- BS.readFile f
                let hash = miniHash content
                return (f ++ " " ++ hash)
                ) sortedFiles
            let commitContent = "parent: " ++ parent ++ "\n"
                             ++ "timestamp: " ++ timestamp ++ "\n"
                             ++ "message: " ++ msg ++ "\n"
                             ++ "files:\n"
                             ++ unlines fileLines
            let commitHash = miniHash (BS.pack (map (fromIntegral . fromEnum) commitContent))
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
        message   = drop 9 (ls !! 2)
        parentRaw = drop 8 (ls !! 0)
    putStrLn ("commit " ++ hash)
    putStrLn ("Date: " ++ timestamp)
    putStrLn ("Message: " ++ message)
    if parentRaw /= "NONE"
        then do
            putStrLn ""
            printLog parentRaw
        else return ()

parseCommitFiles :: String -> [(String, String)]
parseCommitFiles content =
    let ls = lines content
        afterFiles = drop 1 $ dropWhile (/= "files:") ls
        parseEntry line = case words line of
            [fname, hash] -> (fname, hash)
            _             -> ("", "")
    in filter (\(a,_) -> not (null a)) $ map parseEntry afterFiles

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
                files2 = parseCommitFiles content2
                allNames = sort $ nubOrd $ map fst files1 ++ map fst files2
            mapM_ (\name -> do
                let h1 = lookup name files1
                    h2 = lookup name files2
                case (h1, h2) of
                    (Nothing, Just _)  -> putStrLn ("Added: " ++ name)
                    (Just _, Nothing)  -> putStrLn ("Removed: " ++ name)
                    (Just a, Just b)   -> if a /= b
                                            then putStrLn ("Modified: " ++ name)
                                            else return ()
                    _                  -> return ()
                ) allNames

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
                blobContent <- BS.readFile (objectsDir ++ "/" ++ blobHash)
                BS.writeFile fname blobContent
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
            writeFile indexFile (concatMap (++ "\n") newEntries)
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
                timestamp = drop 11 (ls !! 1)
                message   = drop 9 (ls !! 2)
                files = parseCommitFiles content
            putStrLn ("commit " ++ hash)
            putStrLn ("Date: " ++ timestamp)
            putStrLn ("Message: " ++ message)
            putStrLn "Files:"
            mapM_ (\(fname, blobHash) -> putStrLn ("  " ++ fname ++ " " ++ blobHash)) (sort files)

readFileStrict :: FilePath -> IO String
readFileStrict path = do
    content <- readFile path
    length content `seq` return content

-- Simple nub for sorted-friendly dedup
nubOrd :: Ord a => [a] -> [a]
nubOrd = go []
  where
    go _ [] = []
    go seen (x:xs)
        | x `elem` seen = go seen xs
        | otherwise      = x : go (x:seen) xs
