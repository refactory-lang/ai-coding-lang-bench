module Main where

import System.Environment (getArgs)
import System.Directory (createDirectoryIfMissing, doesFileExist, doesDirectoryExist)
import System.Exit (exitWith, ExitCode(..), exitFailure)
import Data.Word (Word64, Word8)
import Data.Bits (xor)
import Data.List (sort, isPrefixOf)
import Data.Char (intToDigit)
import qualified Data.ByteString as BS
import Foreign.C.Types (CTime(..))
import Foreign.Ptr (Ptr, nullPtr)

foreign import ccall "time" c_time :: Ptr CTime -> IO CTime

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

-- MiniHash: FNV-1a variant
miniHash :: BS.ByteString -> String
miniHash bs = toHex16 h
  where
    h = BS.foldl' step 1469598103934665603 bs
    step :: Word64 -> Word8 -> Word64
    step acc b = (acc `xor` fromIntegral b) * 1099511628211

toHex16 :: Word64 -> String
toHex16 w = map toHexDigit [15,14..0]
  where
    toHexDigit i = intToDigit (fromIntegral ((w `div` (16 ^ i)) `mod` 16))

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
            exitWith (ExitFailure 1)
        else do
            content <- BS.readFile file
            let hash = miniHash content
            BS.writeFile (".minigit/objects/" ++ hash) content
            -- Add to index if not already present
            idx <- readFileStrict ".minigit/index"
            let entries = filter (not . null) (lines idx)
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
            exitWith (ExitFailure 1)
        else do
            headContent <- readFileStrict ".minigit/HEAD"
            let parent = if null headContent then "NONE" else headContent
            CTime t <- c_time nullPtr
            let timestamp = show t
            -- Build file entries: for each staged file, get its blob hash
            fileEntries <- mapM (\f -> do
                content <- BS.readFile f
                let hash = miniHash content
                return (f, hash)
                ) (sort entries)
            let filesSection = unlines (map (\(f, h) -> f ++ " " ++ h) fileEntries)
            let commitContent = "parent: " ++ parent ++ "\n"
                             ++ "timestamp: " ++ timestamp ++ "\n"
                             ++ "message: " ++ msg ++ "\n"
                             ++ "files:\n"
                             ++ filesSection
            let commitHash = miniHash (stringToBS commitContent)
            writeFile (".minigit/commits/" ++ commitHash) commitContent
            writeFile ".minigit/HEAD" commitHash
            writeFile ".minigit/index" ""
            putStrLn ("Committed " ++ commitHash)

cmdLog :: IO ()
cmdLog = do
    headContent <- readFileStrict ".minigit/HEAD"
    if null headContent
        then putStrLn "No commits"
        else walkLog headContent

walkLog :: String -> IO ()
walkLog hash = do
    content <- readFileStrict (".minigit/commits/" ++ hash)
    let ls = lines content
    let timestamp = extractField "timestamp: " ls
    let message = extractField "message: " ls
    let parent = extractField "parent: " ls
    putStrLn ("commit " ++ hash)
    putStrLn ("Date: " ++ timestamp)
    putStrLn ("Message: " ++ message)
    if parent /= "NONE"
        then do
            putStrLn ""
            walkLog parent
        else return ()

cmdStatus :: IO ()
cmdStatus = do
    idx <- readFileStrict ".minigit/index"
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
            exitWith (ExitFailure 1)
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
                    _ -> return ()
                ) allFiles

cmdCheckout :: String -> IO ()
cmdCheckout hash = do
    exists <- doesFileExist (".minigit/commits/" ++ hash)
    if not exists
        then do
            putStrLn "Invalid commit"
            exitWith (ExitFailure 1)
        else do
            files <- parseCommitFiles hash
            mapM_ (\(fname, bhash) -> do
                content <- BS.readFile (".minigit/objects/" ++ bhash)
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
            exitWith (ExitFailure 1)
        else do
            writeFile ".minigit/HEAD" hash
            writeFile ".minigit/index" ""
            putStrLn ("Reset to " ++ hash)

cmdRm :: String -> IO ()
cmdRm file = do
    idx <- readFileStrict ".minigit/index"
    let entries = filter (not . null) (lines idx)
    if file `elem` entries
        then writeFile ".minigit/index" (unlines (filter (/= file) entries))
        else do
            putStrLn "File not in index"
            exitWith (ExitFailure 1)

cmdShow :: String -> IO ()
cmdShow hash = do
    exists <- doesFileExist (".minigit/commits/" ++ hash)
    if not exists
        then do
            putStrLn "Invalid commit"
            exitWith (ExitFailure 1)
        else do
            content <- readFileStrict (".minigit/commits/" ++ hash)
            let ls = lines content
            let timestamp = extractField "timestamp: " ls
            let message = extractField "message: " ls
            files <- parseCommitFiles hash
            putStrLn ("commit " ++ hash)
            putStrLn ("Date: " ++ timestamp)
            putStrLn ("Message: " ++ message)
            putStrLn "Files:"
            mapM_ (\(f, h) -> putStrLn ("  " ++ f ++ " " ++ h)) (sort files)

parseCommitFiles :: String -> IO [(String, String)]
parseCommitFiles hash = do
    content <- readFileStrict (".minigit/commits/" ++ hash)
    let ls = lines content
    let afterFiles = drop 1 (dropWhile (/= "files:") ls)
    return [ (w1, w2) | line <- afterFiles, not (null line), let ws = words line, length ws == 2, let w1 = head ws, let w2 = ws !! 1 ]

unique :: Eq a => [a] -> [a]
unique [] = []
unique (x:xs) = x : unique (filter (/= x) xs)

extractField :: String -> [String] -> String
extractField prefix ls =
    case filter (isPrefixOf prefix) ls of
        (x:_) -> drop (length prefix) x
        [] -> ""

readFileStrict :: FilePath -> IO String
readFileStrict path = do
    bs <- BS.readFile path
    return (map (toEnum . fromIntegral) (BS.unpack bs))

stringToBS :: String -> BS.ByteString
stringToBS = BS.pack . map (fromIntegral . fromEnum)
