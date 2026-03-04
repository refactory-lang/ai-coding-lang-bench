module Main where

import System.Environment (getArgs)
import System.Directory (createDirectoryIfMissing, doesFileExist, doesDirectoryExist)
import System.Exit (exitFailure)
import Data.Word (Word8, Word64)
import Data.Bits (xor)
import Data.List (sort, isPrefixOf)
import qualified Data.ByteString as BS
import Numeric (showHex)
import Foreign.Ptr (nullPtr, Ptr)
import Foreign.C.Types (CTime(..))

-- FFI to get unix timestamp
foreign import ccall unsafe "time" c_time :: Ptr CTime -> IO CTime

getTimestamp :: IO String
getTimestamp = do
    CTime t <- c_time nullPtr
    return (show t)

-- MiniHash: FNV-1a variant, 64-bit, 16-char hex output
miniHash :: BS.ByteString -> String
miniHash bs = zeroPad 16 $ showHex finalH ""
  where
    initialH :: Word64
    initialH = 1469598103934665603
    finalH = BS.foldl' step initialH bs
    step :: Word64 -> Word8 -> Word64
    step h b = (h `xor` fromIntegral b) * 1099511628211

zeroPad :: Int -> String -> String
zeroPad n s = replicate (n - length s) '0' ++ s

minigitDir :: FilePath
minigitDir = ".minigit"

objectsDir :: FilePath
objectsDir = minigitDir ++ "/objects"

commitsDir :: FilePath
commitsDir = minigitDir ++ "/commits"

indexFile :: FilePath
indexFile = minigitDir ++ "/index"

headFile :: FilePath
headFile = minigitDir ++ "/HEAD"

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
            putStrLn "Unknown command"
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
            let entries = parseIndex idx
            if file `elem` entries
                then return ()
                else writeFile indexFile (unlines (entries ++ [file]))

parseIndex :: String -> [String]
parseIndex s = filter (not . null) (lines s)

cmdCommit :: String -> IO ()
cmdCommit msg = do
    idx <- readFile indexFile
    let entries = parseIndex idx
    if null entries
        then do
            putStrLn "Nothing to commit"
            exitFailure
        else do
            headContent <- readFile headFile
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
            writeFile (commitsDir ++ "/" ++ commitHash) commitContent
            writeFile headFile commitHash
            writeFile indexFile ""
            putStrLn ("Committed " ++ commitHash)

cmdLog :: IO ()
cmdLog = do
    headContent <- readFile headFile
    if null headContent
        then putStrLn "No commits"
        else printLog headContent

printLog :: String -> IO ()
printLog hash = do
    content <- readFile (commitsDir ++ "/" ++ hash)
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
            printLog parent
        else return ()

extractField :: String -> [String] -> String
extractField prefix ls =
    case filter (isPrefixOf prefix) ls of
        (x:_) -> drop (length prefix) x
        [] -> ""

strToBS :: String -> BS.ByteString
strToBS = BS.pack . map (fromIntegral . fromEnum)

cmdStatus :: IO ()
cmdStatus = do
    idx <- readFile indexFile
    let entries = parseIndex idx
    putStrLn "Staged files:"
    if null entries
        then putStrLn "(none)"
        else mapM_ putStrLn entries

cmdDiff :: String -> String -> IO ()
cmdDiff c1 c2 = do
    e1 <- doesFileExist (commitsDir ++ "/" ++ c1)
    e2 <- doesFileExist (commitsDir ++ "/" ++ c2)
    if not (e1 && e2)
        then do
            putStrLn "Invalid commit"
            exitFailure
        else do
            files1 <- getCommitFiles c1
            files2 <- getCommitFiles c2
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

unique :: Eq a => [a] -> [a]
unique [] = []
unique (x:xs) = x : unique (filter (/= x) xs)

getCommitFiles :: String -> IO [(String, String)]
getCommitFiles hash = do
    content <- readFile (commitsDir ++ "/" ++ hash)
    let ls = lines content
    let filesSection = takeWhile (not . null) $ drop 1 $ dropWhile (/= "files:") ls
    return $ map parseFileLine filesSection

parseFileLine :: String -> (String, String)
parseFileLine s = let (name, rest) = break (== ' ') s
                  in (name, drop 1 rest)

cmdCheckout :: String -> IO ()
cmdCheckout hash = do
    exists <- doesFileExist (commitsDir ++ "/" ++ hash)
    if not exists
        then do
            putStrLn "Invalid commit"
            exitFailure
        else do
            files <- getCommitFiles hash
            mapM_ (\(fname, bhash) -> do
                content <- BS.readFile (objectsDir ++ "/" ++ bhash)
                BS.writeFile fname content
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
    let entries = parseIndex idx
    if file `elem` entries
        then do
            let newEntries = filter (/= file) entries
            writeFile indexFile (if null newEntries then "" else unlines newEntries)
        else do
            putStrLn "File not in index"
            exitFailure

readFileStrict :: FilePath -> IO String
readFileStrict path = do
    bs <- BS.readFile path
    return (map (toEnum . fromIntegral) (BS.unpack bs))

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
            let timestamp = extractField "timestamp: " ls
            let message = extractField "message: " ls
            files <- getCommitFiles hash
            putStrLn ("commit " ++ hash)
            putStrLn ("Date: " ++ timestamp)
            putStrLn ("Message: " ++ message)
            putStrLn "Files:"
            mapM_ (\(fname, bhash) -> putStrLn ("  " ++ fname ++ " " ++ bhash)) (sort files)
