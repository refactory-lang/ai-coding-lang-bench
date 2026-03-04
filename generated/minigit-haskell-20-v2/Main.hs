module Main where

import Data.Bits (xor)
import Data.Char (ord)
import Data.List (sort, nub, intercalate)
import Data.Word (Word64, Word8)
import System.Directory (createDirectoryIfMissing, doesFileExist, doesDirectoryExist, listDirectory)
import System.Environment (getArgs)
import System.Exit (exitFailure, exitSuccess)
import System.IO (hPutStrLn, stderr)
import Data.Time.Clock.POSIX (getPOSIXTime)
import qualified Data.ByteString as BS
import Numeric (showHex)

miniHash :: BS.ByteString -> String
miniHash bs = pad 16 $ showHex (BS.foldl' step 1469598103934665603 bs) ""
  where
    step :: Word64 -> Word8 -> Word64
    step h b = (h `xor` fromIntegral b) * 1099511628211
    pad n s = replicate (n - length s) '0' ++ s

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
            let sortedFiles = sort entries
            fileLines <- mapM (\f -> do
                content <- BS.readFile f
                let hash = miniHash content
                return (f ++ " " ++ hash)) sortedFiles
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
        parentLine = head ls
        parent = drop 8 parentLine  -- "parent: " is 8 chars
        timestampLine = ls !! 1
        timestamp = drop 11 timestampLine  -- "timestamp: " is 11 chars
        messageLine = ls !! 2
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

parseCommitFiles :: String -> [(String, String)]
parseCommitFiles content =
    let ls = lines content
        afterFiles = drop 1 (dropWhile (/= "files:") ls)
        parseFileLine l = case words l of
            [fname, hash] -> (fname, hash)
            _ -> ("", "")
    in filter (\(f, _) -> not (null f)) (map parseFileLine afterFiles)

cmdDiff :: String -> String -> IO ()
cmdDiff c1 c2 = do
    let p1 = ".minigit/commits/" ++ c1
        p2 = ".minigit/commits/" ++ c2
    e1 <- doesFileExist p1
    e2 <- doesFileExist p2
    if not e1 || not e2
        then do
            putStrLn "Invalid commit"
            exitFailure
        else do
            content1 <- readFile p1
            content2 <- readFile p2
            let files1 = parseCommitFiles content1
                files2 = parseCommitFiles content2
                allNames = sort $ nub (map fst files1 ++ map fst files2)
            mapM_ (\name -> do
                let h1 = lookup name files1
                    h2 = lookup name files2
                case (h1, h2) of
                    (Nothing, Just _)  -> putStrLn ("Added: " ++ name)
                    (Just _, Nothing)  -> putStrLn ("Removed: " ++ name)
                    (Just a, Just b)   -> if a /= b then putStrLn ("Modified: " ++ name) else return ()
                    _ -> return ()
                ) allNames

cmdCheckout :: String -> IO ()
cmdCheckout hash = do
    let path = ".minigit/commits/" ++ hash
    exists <- doesFileExist path
    if not exists
        then do
            putStrLn "Invalid commit"
            exitFailure
        else do
            content <- readFile path
            let files = parseCommitFiles content
            mapM_ (\(fname, blobHash) -> do
                blob <- BS.readFile (".minigit/objects/" ++ blobHash)
                BS.writeFile fname blob
                ) files
            writeFile ".minigit/HEAD" hash
            writeFile ".minigit/index" ""
            putStrLn ("Checked out " ++ hash)

cmdReset :: String -> IO ()
cmdReset hash = do
    let path = ".minigit/commits/" ++ hash
    exists <- doesFileExist path
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
    idx <- readFile ".minigit/index"
    let entries = filter (not . null) (lines idx)
    if file `elem` entries
        then do
            let newEntries = unlines (filter (/= file) entries)
            length newEntries `seq` writeFile ".minigit/index" newEntries
        else do
            putStrLn "File not in index"
            exitFailure

cmdShow :: String -> IO ()
cmdShow hash = do
    let path = ".minigit/commits/" ++ hash
    exists <- doesFileExist path
    if not exists
        then do
            putStrLn "Invalid commit"
            exitFailure
        else do
            content <- readFile path
            let ls = lines content
                timestamp = drop 11 (ls !! 1)
                message = drop 9 (ls !! 2)
                files = parseCommitFiles content
            putStrLn ("commit " ++ hash)
            putStrLn ("Date: " ++ timestamp)
            putStrLn ("Message: " ++ message)
            putStrLn "Files:"
            mapM_ (\(fname, blobHash) -> putStrLn ("  " ++ fname ++ " " ++ blobHash)) (sort files)
