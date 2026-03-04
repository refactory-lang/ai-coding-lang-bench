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
    if not (e1 && e2)
        then do
            putStrLn "Invalid commit"
            exitFailure
        else do
            files1 <- parseCommitFiles c1
            files2 <- parseCommitFiles c2
            let allFiles = sort $ nub (map fst files1 ++ map fst files2)
            mapM_ (\f -> do
                let in1 = lookup f files1
                    in2 = lookup f files2
                case (in1, in2) of
                    (Nothing, Just _)  -> putStrLn ("Added: " ++ f)
                    (Just _, Nothing)  -> putStrLn ("Removed: " ++ f)
                    (Just h1, Just h2) -> if h1 /= h2
                                            then putStrLn ("Modified: " ++ f)
                                            else return ()
                    _ -> return ()
                ) allFiles

parseCommitFiles :: String -> IO [(String, String)]
parseCommitFiles hash = do
    content <- readFile (".minigit/commits/" ++ hash)
    let ls = lines content
        afterFiles = drop 1 (dropWhile (/= "files:") ls)
        parsed = map parseFileLine (filter (not . null) afterFiles)
    return parsed
  where
    parseFileLine l = let ws = words l in (head ws, ws !! 1)

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
    if file `elem` entries
        then do
            let newEntries = filter (/= file) entries
            writeFile ".minigit/index" (if null newEntries then "" else unlines newEntries)
        else do
            putStrLn "File not in index"
            exitFailure

readFileStrict :: FilePath -> IO String
readFileStrict path = do
    content <- BS.readFile path
    return (map (toEnum . fromIntegral) (BS.unpack content))

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
                afterFiles = drop 1 (dropWhile (/= "files:") ls)
                fileEntries = filter (not . null) afterFiles
            putStrLn ("commit " ++ hash)
            putStrLn ("Date: " ++ timestamp)
            putStrLn ("Message: " ++ message)
            putStrLn "Files:"
            mapM_ (\l -> putStrLn ("  " ++ l)) (sort fileEntries)

stringToBS :: String -> BS.ByteString
stringToBS = BS.pack . map (fromIntegral . ord)
