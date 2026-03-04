module Main where

import Data.Bits (xor)
import Data.Char (intToDigit, ord)
import Data.List (sort)
import Data.Word (Word64, Word8)
import System.Directory (createDirectoryIfMissing, doesFileExist, doesDirectoryExist)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import qualified Data.ByteString as BS
import Data.Time.Clock.POSIX (getPOSIXTime)

main :: IO ()
main = do
    args <- getArgs
    case args of
        ("init" : _)                 -> cmdInit
        ("add" : file : _)          -> cmdAdd file
        ("commit" : "-m" : msg : _) -> cmdCommit msg
        ("status" : _)              -> cmdStatus
        ("log" : _)                 -> cmdLog
        ("diff" : c1 : c2 : _)     -> cmdDiff c1 c2
        ("checkout" : hash : _)     -> cmdCheckout hash
        ("reset" : hash : _)        -> cmdReset hash
        ("rm" : file : _)           -> cmdRm file
        ("show" : hash : _)         -> cmdShow hash
        _                           -> putStrLn "Usage: minigit <command>" >> exitFailure

-- MiniHash: FNV-1a variant, 64-bit, 16-char hex
miniHash :: BS.ByteString -> String
miniHash bs = pad16 (toHex finalH)
  where
    initialH :: Word64
    initialH = 1469598103934665603
    finalH = BS.foldl' step initialH bs
    step :: Word64 -> Word8 -> Word64
    step h b = (h `xor` fromIntegral b) * 1099511628211

toHex :: Word64 -> String
toHex 0 = "0"
toHex n = go n ""
  where
    go 0 acc = acc
    go v acc = go (v `div` 16) (intToDigit (fromIntegral (v `mod` 16)) : acc)

pad16 :: String -> String
pad16 s = replicate (16 - length s) '0' ++ s

strToBS :: String -> BS.ByteString
strToBS = BS.pack . map (fromIntegral . ord)

-- init
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

-- add
cmdAdd :: String -> IO ()
cmdAdd file = do
    exists <- doesFileExist file
    if not exists
        then putStrLn "File not found" >> exitFailure
        else do
            content <- BS.readFile file
            let hash = miniHash content
            BS.writeFile (".minigit/objects/" ++ hash) content
            indexContent <- readFile ".minigit/index"
            let entries = filter (not . null) (lines indexContent)
            if file `elem` entries
                then return ()
                else writeFile ".minigit/index" (unlines (entries ++ [file]))

-- commit
cmdCommit :: String -> IO ()
cmdCommit msg = do
    indexContent <- readFile ".minigit/index"
    let entries = filter (not . null) (lines indexContent)
    if null entries
        then putStrLn "Nothing to commit" >> exitFailure
        else do
            headContent <- readFile ".minigit/HEAD"
            let parent = if null headContent then "NONE" else headContent
            now <- getPOSIXTime
            let timestamp = show (floor now :: Integer)
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
            let commitHash = miniHash (strToBS commitContent)
            writeFile (".minigit/commits/" ++ commitHash) commitContent
            writeFile ".minigit/HEAD" commitHash
            writeFile ".minigit/index" ""
            putStrLn ("Committed " ++ commitHash)

-- log
cmdLog :: IO ()
cmdLog = do
    headContent <- readFile ".minigit/HEAD"
    if null headContent
        then putStrLn "No commits"
        else printLog headContent

printLog :: String -> IO ()
printLog "NONE" = return ()
printLog hash = do
    content <- readFile (".minigit/commits/" ++ hash)
    let ls = lines content
        parent = drop 8 (ls !! 0)     -- "parent: " is 8 chars
        timestamp = drop 11 (ls !! 1) -- "timestamp: " is 11 chars
        message = drop 9 (ls !! 2)    -- "message: " is 9 chars
    putStrLn ("commit " ++ hash)
    putStrLn ("Date: " ++ timestamp)
    putStrLn ("Message: " ++ message)
    putStrLn ""
    printLog parent

-- status
cmdStatus :: IO ()
cmdStatus = do
    indexContent <- readFile ".minigit/index"
    let entries = filter (not . null) (lines indexContent)
    putStrLn "Staged files:"
    if null entries
        then putStrLn "(none)"
        else mapM_ putStrLn entries

-- diff
cmdDiff :: String -> String -> IO ()
cmdDiff c1 c2 = do
    exists1 <- doesFileExist (".minigit/commits/" ++ c1)
    exists2 <- doesFileExist (".minigit/commits/" ++ c2)
    if not exists1 || not exists2
        then putStrLn "Invalid commit" >> exitFailure
        else do
            files1 <- parseCommitFiles c1
            files2 <- parseCommitFiles c2
            let allFiles = sort $ nub (map fst files1 ++ map fst files2)
            mapM_ (diffFile files1 files2) allFiles

nub :: Eq a => [a] -> [a]
nub [] = []
nub (x:xs) = x : nub (filter (/= x) xs)

parseCommitFiles :: String -> IO [(String, String)]
parseCommitFiles hash = do
    content <- readFile (".minigit/commits/" ++ hash)
    let ls = lines content
        fileLines = drop 1 (dropWhile (/= "files:") ls)
        parsed = map parseFileLine (filter (not . null) fileLines)
    return parsed

parseFileLine :: String -> (String, String)
parseFileLine line = case break (== ' ') line of
    (name, ' ':hash) -> (name, hash)
    _                -> (line, "")

diffFile :: [(String, String)] -> [(String, String)] -> String -> IO ()
diffFile files1 files2 name = do
    let h1 = lookup name files1
        h2 = lookup name files2
    case (h1, h2) of
        (Nothing, Just _)  -> putStrLn ("Added: " ++ name)
        (Just _, Nothing)  -> putStrLn ("Removed: " ++ name)
        (Just a, Just b)   -> if a /= b then putStrLn ("Modified: " ++ name) else return ()
        _                  -> return ()

-- checkout
cmdCheckout :: String -> IO ()
cmdCheckout hash = do
    exists <- doesFileExist (".minigit/commits/" ++ hash)
    if not exists
        then putStrLn "Invalid commit" >> exitFailure
        else do
            files <- parseCommitFiles hash
            mapM_ (\(name, blobHash) -> do
                content <- BS.readFile (".minigit/objects/" ++ blobHash)
                BS.writeFile name content
                ) files
            writeFile ".minigit/HEAD" hash
            writeFile ".minigit/index" ""
            putStrLn ("Checked out " ++ hash)

-- reset
cmdReset :: String -> IO ()
cmdReset hash = do
    exists <- doesFileExist (".minigit/commits/" ++ hash)
    if not exists
        then putStrLn "Invalid commit" >> exitFailure
        else do
            writeFile ".minigit/HEAD" hash
            writeFile ".minigit/index" ""
            putStrLn ("Reset to " ++ hash)

-- rm
cmdRm :: String -> IO ()
cmdRm file = do
    indexContent <- readFile ".minigit/index"
    let entries = filter (not . null) (lines indexContent)
    if file `elem` entries
        then do
            let newEntries = filter (/= file) entries
            seq (length indexContent) (writeFile ".minigit/index" (unlines newEntries))
        else putStrLn "File not in index" >> exitFailure

-- show
cmdShow :: String -> IO ()
cmdShow hash = do
    exists <- doesFileExist (".minigit/commits/" ++ hash)
    if not exists
        then putStrLn "Invalid commit" >> exitFailure
        else do
            content <- readFile (".minigit/commits/" ++ hash)
            let ls = lines content
                timestamp = drop 11 (ls !! 1)
                message = drop 9 (ls !! 2)
            files <- parseCommitFiles hash
            putStrLn ("commit " ++ hash)
            putStrLn ("Date: " ++ timestamp)
            putStrLn ("Message: " ++ message)
            putStrLn "Files:"
            mapM_ (\(name, blobHash) -> putStrLn ("  " ++ name ++ " " ++ blobHash)) (sort files)
