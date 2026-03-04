module Main where

import Data.Bits (xor)
import Data.Char (ord)
import Data.List (sort, intercalate, isPrefixOf)
import Data.Word (Word64)
import System.Directory (createDirectoryIfMissing, doesFileExist, doesDirectoryExist, listDirectory)
import System.Environment (getArgs)
import System.Exit (exitFailure, exitWith, ExitCode(..))
import System.IO (hPutStrLn, stderr)
import qualified Data.ByteString as BS
import Numeric (showHex)
import Data.Time.Clock.POSIX (getPOSIXTime)

miniHash :: BS.ByteString -> String
miniHash bs = replicate (16 - length hexStr) '0' ++ hexStr
  where
    h0 :: Word64
    h0 = 1469598103934665603
    final = BS.foldl' step h0 bs
    step h b = (h `xor` fromIntegral b) * 1099511628211
    hexStr = showHex final ""

main :: IO ()
main = do
    args <- getArgs
    case args of
        ["init"] -> cmdInit
        ["add", file] -> cmdAdd file
        ["commit", "-m", msg] -> cmdCommit msg
        ["status"] -> cmdStatus
        ["log"] -> cmdLog
        ["diff", c1, c2] -> cmdDiff c1 c2
        ["checkout", hash] -> cmdCheckout hash
        ["reset", hash] -> cmdReset hash
        ["rm", file] -> cmdRm file
        ["show", hash] -> cmdShow hash
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
            idx <- readFileStrict ".minigit/index"
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
            -- Build file entries: for each file in sorted order, get its blob hash
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
            let commitHash = miniHash (BS.pack (map (fromIntegral . ord) commitContent))
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
    let parentLine = head ls
        parent = drop 8 parentLine  -- "parent: " is 8 chars
    let timestampLine = ls !! 1
        timestamp = drop 11 timestampLine  -- "timestamp: " is 11 chars
    let messageLine = ls !! 2
        message = drop 9 messageLine  -- "message: " is 9 chars
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
    idx <- readFile ".minigit/index"
    let entries = filter (not . null) (lines idx)
    putStrLn "Staged files:"
    if null entries
        then putStrLn "(none)"
        else mapM_ putStrLn entries

cmdDiff :: String -> String -> IO ()
cmdDiff c1 c2 = do
    e1 <- doesFileExist (".minigit/commits/" ++ c1)
    e2 <- doesFileExist (".minigit/commits/" ++ c2)
    if not e1 || not e2
        then do
            putStrLn "Invalid commit"
            exitFailure
        else do
            files1 <- parseCommitFiles c1
            files2 <- parseCommitFiles c2
            let allFiles = sort $ unique (map fst files1 ++ map fst files2)
            mapM_ (\f -> do
                let h1 = lookup f files1
                    h2 = lookup f files2
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
    content <- readFile (".minigit/commits/" ++ hash)
    let ls = lines content
        fileLines = drop 1 (dropWhile (/= "files:") ls)
        parsed = map parseFileLine (filter (not . null) fileLines)
    return parsed

parseFileLine :: String -> (String, String)
parseFileLine line =
    let (name, rest) = break (== ' ') line
    in (name, drop 1 rest)

cmdCheckout :: String -> IO ()
cmdCheckout hash = do
    exists <- doesFileExist (".minigit/commits/" ++ hash)
    if not exists
        then do
            putStrLn "Invalid commit"
            exitFailure
        else do
            files <- parseCommitFiles hash
            mapM_ (\(fname, blobHash) -> do
                content <- BS.readFile (".minigit/objects/" ++ blobHash)
                BS.writeFile fname content
                ) files
            writeFile ".minigit/HEAD" hash
            writeFile ".minigit/index" ""
            putStrLn ("Checked out " ++ hash)

cmdReset :: String -> IO ()
cmdReset hash = do
    exists <- doesFileExist (".minigit/commits/" ++ hash)
    if not exists
        then do
            putStrLn "Invalid commit"
            exitFailure
        else do
            writeFile ".minigit/HEAD" hash
            writeFile ".minigit/index" ""
            putStrLn ("Reset to " ++ hash)

cmdRm :: String -> IO ()
cmdRm file = do
    idx <- readFileStrict ".minigit/index"
    let entries = filter (not . null) (lines idx)
    if file `notElem` entries
        then do
            putStrLn "File not in index"
            exitFailure
        else do
            let newEntries = filter (/= file) entries
            writeFile ".minigit/index" (if null newEntries then "" else unlines newEntries)

readFileStrict :: FilePath -> IO String
readFileStrict path = do
    bs <- BS.readFile path
    return (map (toEnum . fromIntegral) (BS.unpack bs))

cmdShow :: String -> IO ()
cmdShow hash = do
    exists <- doesFileExist (".minigit/commits/" ++ hash)
    if not exists
        then do
            putStrLn "Invalid commit"
            exitFailure
        else do
            content <- readFile (".minigit/commits/" ++ hash)
            let ls = lines content
                timestamp = drop 11 (ls !! 1)
                message = drop 9 (ls !! 2)
                fileLines = drop 1 (dropWhile (/= "files:") ls)
                validFiles = filter (not . null) fileLines
            putStrLn ("commit " ++ hash)
            putStrLn ("Date: " ++ timestamp)
            putStrLn ("Message: " ++ message)
            putStrLn "Files:"
            mapM_ (\f -> putStrLn ("  " ++ f)) validFiles
