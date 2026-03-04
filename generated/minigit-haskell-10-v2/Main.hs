module Main where

import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist)
import Data.Word (Word8, Word64)
import Data.Bits (xor)
import Data.List (sort, intercalate)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Numeric (showHex)
import Foreign.C.Types (CTime(..))
import Foreign.Ptr (Ptr, nullPtr)

foreign import ccall "time" c_time :: Ptr CTime -> IO CTime

minigitDir :: String
minigitDir = ".minigit"

objectsDir :: String
objectsDir = minigitDir ++ "/objects"

commitsDir :: String
commitsDir = minigitDir ++ "/commits"

indexFile :: String
indexFile = minigitDir ++ "/index"

headFile :: String
headFile = minigitDir ++ "/HEAD"

miniHash :: BS.ByteString -> String
miniHash bs = zeroPad 16 $ showHex result ""
  where
    result = BS.foldl' step 1469598103934665603 bs
    step :: Word64 -> Word8 -> Word64
    step h b = (h `xor` fromIntegral b) * 1099511628211

zeroPad :: Int -> String -> String
zeroPad n s = replicate (n - length s) '0' ++ s

strToBS :: String -> BS.ByteString
strToBS = BS.pack . map (fromIntegral . fromEnum)

readFileStrict :: FilePath -> IO String
readFileStrict path = do
    bs <- BS.readFile path
    return (BC.unpack bs)

getUnixTime :: IO Integer
getUnixTime = do
    CTime t <- c_time nullPtr
    return (fromIntegral t)

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
        _ -> putStrLn "Usage: minigit <command>" >> exitFailure

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

cmdAdd :: String -> IO ()
cmdAdd file = do
    exists <- doesFileExist file
    if not exists
        then putStrLn "File not found" >> exitFailure
        else do
            content <- BS.readFile file
            let hash = miniHash content
            BS.writeFile (objectsDir ++ "/" ++ hash) content
            idx <- readFileStrict indexFile
            let entries = filter (not . null) (lines idx)
            if file `elem` entries
                then return ()
                else writeFile indexFile (unlines (entries ++ [file]))

cmdCommit :: String -> IO ()
cmdCommit msg = do
    idx <- readFileStrict indexFile
    let entries = filter (not . null) (lines idx)
    if null entries
        then putStrLn "Nothing to commit" >> exitFailure
        else do
            headContent <- readFileStrict headFile
            let parent = if null headContent then "NONE" else headContent
            timestamp <- getUnixTime
            fileEntries <- mapM (\f -> do
                content <- BS.readFile f
                let hash = miniHash content
                return (f ++ " " ++ hash)
                ) (sort entries)
            let commitContent = "parent: " ++ parent ++ "\n"
                             ++ "timestamp: " ++ show timestamp ++ "\n"
                             ++ "message: " ++ msg ++ "\n"
                             ++ "files:\n"
                             ++ unlines fileEntries
            let commitHash = miniHash (strToBS commitContent)
            writeFile (commitsDir ++ "/" ++ commitHash) commitContent
            writeFile headFile commitHash
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
    content <- readFileStrict (commitsDir ++ "/" ++ hash)
    let ls = lines content
        parent = drop 8 (ls !! 0)
        timestamp = drop 11 (ls !! 1)
        message = drop 9 (ls !! 2)
    putStrLn ("commit " ++ hash)
    putStrLn ("Date: " ++ timestamp)
    putStrLn ("Message: " ++ message)
    if parent /= "NONE"
        then putStrLn "" >> printLog parent
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
        then putStrLn "Invalid commit" >> exitFailure
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
    content <- readFileStrict (commitsDir ++ "/" ++ hash)
    let ls = lines content
        fileLines = drop 1 (dropWhile (/= "files:") ls)
        parsed = map parseFileLine (filter (not . null) fileLines)
    return parsed

parseFileLine :: String -> (String, String)
parseFileLine line = case words line of
    [name, hash] -> (name, hash)
    _            -> ("", "")

cmdCheckout :: String -> IO ()
cmdCheckout hash = do
    exists <- doesFileExist (commitsDir ++ "/" ++ hash)
    if not exists
        then putStrLn "Invalid commit" >> exitFailure
        else do
            files <- parseCommitFiles hash
            mapM_ (\(name, blobHash) -> do
                content <- BS.readFile (objectsDir ++ "/" ++ blobHash)
                BS.writeFile name content
                ) files
            writeFile headFile hash
            writeFile indexFile ""
            putStrLn ("Checked out " ++ hash)

cmdReset :: String -> IO ()
cmdReset hash = do
    exists <- doesFileExist (commitsDir ++ "/" ++ hash)
    if not exists
        then putStrLn "Invalid commit" >> exitFailure
        else do
            writeFile headFile hash
            writeFile indexFile ""
            putStrLn ("Reset to " ++ hash)

cmdRm :: String -> IO ()
cmdRm file = do
    idx <- readFileStrict indexFile
    let entries = filter (not . null) (lines idx)
    if file `elem` entries
        then writeFile indexFile (unlines (filter (/= file) entries))
        else putStrLn "File not in index" >> exitFailure

cmdShow :: String -> IO ()
cmdShow hash = do
    exists <- doesFileExist (commitsDir ++ "/" ++ hash)
    if not exists
        then putStrLn "Invalid commit" >> exitFailure
        else do
            content <- readFileStrict (commitsDir ++ "/" ++ hash)
            let ls = lines content
                timestamp = drop 11 (ls !! 1)
                message = drop 9 (ls !! 2)
            files <- parseCommitFiles hash
            putStrLn ("commit " ++ hash)
            putStrLn ("Date: " ++ timestamp)
            putStrLn ("Message: " ++ message)
            putStrLn "Files:"
            mapM_ (\(name, blobHash) -> putStrLn ("  " ++ name ++ " " ++ blobHash)) (sort files)
