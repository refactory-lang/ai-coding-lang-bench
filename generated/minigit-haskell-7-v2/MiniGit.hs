module Main where

import System.Environment (getArgs)
import System.Directory (createDirectoryIfMissing, doesFileExist, doesDirectoryExist, getDirectoryContents)
import System.Exit (exitFailure, exitSuccess)
import System.IO (hFlush, stdout)
import Data.Word (Word64, Word8)
import Data.Bits (xor)
import Data.List (sort)
import Foreign.Ptr (Ptr, nullPtr)
import Data.Char (intToDigit)
import qualified Data.ByteString as BS

miniHash :: BS.ByteString -> String
miniHash bs = padHex 16 (go 1469598103934665603 (BS.unpack bs))
  where
    go :: Word64 -> [Word8] -> Word64
    go h [] = h
    go h (b:rest) =
      let h' = h `xor` fromIntegral b
          h'' = h' * 1099511628211
      in go h'' rest

    padHex :: Int -> Word64 -> String
    padHex n val =
      let hex = toHex val
          pad = replicate (n - length hex) '0'
      in pad ++ hex

    toHex :: Word64 -> String
    toHex 0 = "0"
    toHex v = reverse (go' v)
      where
        go' 0 = []
        go' x = intToDigit (fromIntegral (x `mod` 16)) : go' (x `div` 16)

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
            putStrLn "Usage: minigit <command>"
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
            indexContent <- strictReadFile ".minigit/index"
            let entries = if null indexContent then [] else lines indexContent
            if file `elem` entries
                then return ()
                else writeFile ".minigit/index" (unlines (entries ++ [file]))

cmdCommit :: String -> IO ()
cmdCommit msg = do
    indexContent <- strictReadFile ".minigit/index"
    let entries = filter (not . null) (lines indexContent)
    if null entries
        then do
            putStrLn "Nothing to commit"
            exitFailure
        else do
            headContent <- strictReadFile ".minigit/HEAD"
            let parent = if null headContent then "NONE" else headContent
            timestamp <- getTimestamp
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
            let commitHash = miniHash (strToBS commitContent)
            writeFile (".minigit/commits/" ++ commitHash) commitContent
            writeFile ".minigit/HEAD" commitHash
            writeFile ".minigit/index" ""
            putStrLn ("Committed " ++ commitHash)

cmdLog :: IO ()
cmdLog = do
    headContent <- strictReadFile ".minigit/HEAD"
    if null headContent
        then putStrLn "No commits"
        else printLog headContent

printLog :: String -> IO ()
printLog hash = do
    let path = ".minigit/commits/" ++ hash
    content <- strictReadFile path
    let ls = lines content
        parentLine = head ls
        timestampLine = ls !! 1
        messageLine = ls !! 2
        parent = drop (length "parent: ") parentLine
        timestamp = drop (length "timestamp: ") timestampLine
        message = drop (length "message: ") messageLine
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
    indexContent <- strictReadFile ".minigit/index"
    let entries = filter (not . null) (lines indexContent)
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

parseCommitFiles :: String -> IO [(String, String)]
parseCommitFiles hash = do
    content <- strictReadFile (".minigit/commits/" ++ hash)
    let ls = lines content
        afterFiles = drop 1 (dropWhile (/= "files:") ls)
        pairs = map parseFileLine (filter (not . null) afterFiles)
    return pairs
  where
    parseFileLine l = let ws = words l in (head ws, ws !! 1)

unique :: Eq a => [a] -> [a]
unique [] = []
unique (x:xs) = x : unique (filter (/= x) xs)

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
    indexContent <- strictReadFile ".minigit/index"
    let entries = filter (not . null) (lines indexContent)
    if file `elem` entries
        then do
            let newEntries = filter (/= file) entries
            writeFile ".minigit/index" (if null newEntries then "" else unlines newEntries)
        else do
            putStrLn "File not in index"
            exitFailure

strictReadFile :: FilePath -> IO String
strictReadFile path = do
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
            content <- strictReadFile (".minigit/commits/" ++ hash)
            let ls = lines content
                timestamp = drop (length "timestamp: ") (ls !! 1)
                message = drop (length "message: ") (ls !! 2)
                afterFiles = drop 1 (dropWhile (/= "files:") ls)
                fileLines = filter (not . null) afterFiles
            putStrLn ("commit " ++ hash)
            putStrLn ("Date: " ++ timestamp)
            putStrLn ("Message: " ++ message)
            putStrLn "Files:"
            mapM_ (\l -> putStrLn ("  " ++ l)) fileLines

getTimestamp :: IO String
getTimestamp = do
    -- Read /proc/uptime is not useful, use POSIX time
    -- We'll use the date command via a simple approach
    -- Since we can only use stdlib, we use Data.Time or System.Posix
    -- Actually, let's use Foreign.C for epoch time
    t <- cTime
    return (show t)

foreign import ccall "time" c_time :: Ptr () -> IO Int

cTime :: IO Int
cTime = c_time nullPtr

strToBS :: String -> BS.ByteString
strToBS = BS.pack . map (fromIntegral . fromEnum)
