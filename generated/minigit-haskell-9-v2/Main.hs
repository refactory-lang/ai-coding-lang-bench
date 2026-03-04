module Main where

import System.Environment (getArgs)
import System.Directory (createDirectoryIfMissing, doesFileExist, doesDirectoryExist)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Data.Word (Word8, Word64)
import Data.Bits (xor)
import Data.Char (ord)
import Data.List (sort)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Numeric (showHex)
import Data.Time.Clock.POSIX (getPOSIXTime)

readFileStrict :: FilePath -> IO String
readFileStrict path = do
    bs <- BS.readFile path
    return (BC.unpack bs)

miniHash :: BS.ByteString -> String
miniHash bs = padHex 16 $ showHex (BS.foldl' step 1469598103934665603 bs) ""
  where
    step :: Word64 -> Word8 -> Word64
    step h b = (h `xor` fromIntegral b) * 1099511628211

    padHex :: Int -> String -> String
    padHex n s = replicate (n - length s) '0' ++ s

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
            idx <- readFileStrict ".minigit/index"
            let entries = if null idx then [] else lines idx
            if file `elem` entries
                then return ()
                else writeFile ".minigit/index" (unlines (entries ++ [file]))

cmdCommit :: String -> IO ()
cmdCommit msg = do
    idx <- readFileStrict ".minigit/index"
    let entries = filter (not . null) (lines idx)
    if null entries
        then do
            putStrLn "Nothing to commit"
            exitFailure
        else do
            let sorted = sort entries
            parent <- readFileStrict ".minigit/HEAD"
            let parentStr = if null parent then "NONE" else parent
            timestamp <- fmap (show . (floor :: Double -> Integer) . realToFrac) getPOSIXTime
            fileLines <- mapM (\f -> do
                content <- BS.readFile f
                let hash = miniHash content
                return (f ++ " " ++ hash)
                ) sorted
            let commitContent = "parent: " ++ parentStr ++ "\n"
                             ++ "timestamp: " ++ timestamp ++ "\n"
                             ++ "message: " ++ msg ++ "\n"
                             ++ "files:\n"
                             ++ unlines fileLines
            let commitHash = miniHash (BS.pack (map (fromIntegral . ord) commitContent))
            writeFile (".minigit/commits/" ++ commitHash) commitContent
            writeFile ".minigit/HEAD" commitHash
            writeFile ".minigit/index" ""
            putStrLn ("Committed " ++ commitHash)

cmdStatus :: IO ()
cmdStatus = do
    idx <- readFileStrict ".minigit/index"
    let entries = filter (not . null) (lines idx)
    putStrLn "Staged files:"
    if null entries
        then putStrLn "(none)"
        else mapM_ putStrLn entries

cmdLog :: IO ()
cmdLog = do
    headContent <- readFileStrict ".minigit/HEAD"
    if null headContent
        then putStrLn "No commits"
        else printLog headContent

printLog :: String -> IO ()
printLog hash = do
    content <- readFileStrict (".minigit/commits/" ++ hash)
    let ls = lines content
        parent = drop 8 (head ls)
        timestamp = drop 11 (ls !! 1)
        message = drop 9 (ls !! 2)
    putStrLn ("commit " ++ hash)
    putStrLn ("Date: " ++ timestamp)
    putStrLn ("Message: " ++ message)
    if parent /= "NONE"
        then do
            putStrLn ""
            printLog parent
        else return ()

parseCommitFiles :: String -> [(String, String)]
parseCommitFiles content =
    let ls = lines content
        fileLines = drop 1 (dropWhile (/= "files:") ls)
    in map parseFileLine (filter (not . null) fileLines)
  where
    parseFileLine l = let (name, rest) = break (== ' ') l
                      in (name, drop 1 rest)

cmdDiff :: String -> String -> IO ()
cmdDiff c1 c2 = do
    e1 <- doesFileExist (".minigit/commits/" ++ c1)
    e2 <- doesFileExist (".minigit/commits/" ++ c2)
    if not (e1 && e2)
        then do
            putStrLn "Invalid commit"
            exitFailure
        else do
            content1 <- readFileStrict (".minigit/commits/" ++ c1)
            content2 <- readFileStrict (".minigit/commits/" ++ c2)
            let files1 = parseCommitFiles content1
                files2 = parseCommitFiles content2
                allNames = sort $ unique (map fst files1 ++ map fst files2)
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
            content <- readFileStrict (".minigit/commits/" ++ hash)
            let files = parseCommitFiles content
            mapM_ (\(name, blobHash) -> do
                blobContent <- BS.readFile (".minigit/objects/" ++ blobHash)
                BS.writeFile name blobContent
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
            writeFile ".minigit/index" (unlines newEntries)

cmdShow :: String -> IO ()
cmdShow hash = do
    exists <- doesFileExist (".minigit/commits/" ++ hash)
    if not exists
        then do
            putStrLn "Invalid commit"
            exitFailure
        else do
            content <- readFileStrict (".minigit/commits/" ++ hash)
            let ls = lines content
                timestamp = drop 11 (ls !! 1)
                message = drop 9 (ls !! 2)
                files = parseCommitFiles content
            putStrLn ("commit " ++ hash)
            putStrLn ("Date: " ++ timestamp)
            putStrLn ("Message: " ++ message)
            putStrLn "Files:"
            mapM_ (\(name, blobHash) -> putStrLn ("  " ++ name ++ " " ++ blobHash)) (sort files)
