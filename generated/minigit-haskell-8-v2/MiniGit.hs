module Main where

import System.Environment (getArgs)
import System.Directory (createDirectoryIfMissing, doesFileExist, doesDirectoryExist)
import System.Exit (exitFailure)
import Data.Word (Word8, Word64)
import Data.Bits (xor)
import Data.List (sort, isPrefixOf)
import qualified Data.ByteString as BS
import Numeric (showHex)
import Data.Char (toLower)
import Data.Time.Clock.POSIX (getPOSIXTime)

minigitDir, objectsDir, commitsDir, indexFile, headFile :: FilePath
minigitDir = ".minigit"
objectsDir = ".minigit/objects"
commitsDir = ".minigit/commits"
indexFile   = ".minigit/index"
headFile    = ".minigit/HEAD"

miniHash :: BS.ByteString -> String
miniHash bs = padHex 16 $ showHex (BS.foldl' step 1469598103934665603 bs) ""
  where
    step :: Word64 -> Word8 -> Word64
    step h b = (h `xor` fromIntegral b) * 1099511628211

padHex :: Int -> String -> String
padHex n s = replicate (max 0 (n - length s)) '0' ++ map toLower s

stringToBS :: String -> BS.ByteString
stringToBS = BS.pack . map (fromIntegral . fromEnum)

readFileStrict :: FilePath -> IO String
readFileStrict path = do
    bs <- BS.readFile path
    return $ map (toEnum . fromIntegral) $ BS.unpack bs

readFileSafe :: FilePath -> IO String
readFileSafe path = do
    exists <- doesFileExist path
    if exists then readFileStrict path else return ""

stripNewlines :: String -> String
stripNewlines = filter (`notElem` "\n\r")

readIndex :: IO [String]
readIndex = do
    content <- readFileSafe indexFile
    return $ filter (not . null) (lines content)

parseCommitFiles :: [String] -> [(String, String)]
parseCommitFiles ls =
    let afterFiles = drop 1 $ dropWhile (/= "files:") ls
    in map parseEntry $ filter (not . null) afterFiles
  where
    parseEntry line = let (fname, rest) = break (== ' ') line
                      in (fname, drop 1 rest)

main :: IO ()
main = do
    args <- getArgs
    case args of
        ["init"]              -> cmdInit
        ["add", file]         -> cmdAdd file
        ["commit", "-m", msg] -> cmdCommit msg
        ["status"]            -> cmdStatus
        ["log"]               -> cmdLog
        ["diff", c1, c2]      -> cmdDiff c1 c2
        ["checkout", hash]    -> cmdCheckout hash
        ["reset", hash]       -> cmdReset hash
        ["rm", file]          -> cmdRm file
        ["show", hash]        -> cmdShow hash
        _                     -> putStrLn "Unknown command" >> exitFailure

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
        then putStrLn "File not found" >> exitFailure
        else do
            content <- BS.readFile file
            let hash = miniHash content
            BS.writeFile (objectsDir ++ "/" ++ hash) content
            entries <- readIndex
            if file `elem` entries
                then return ()
                else writeFile indexFile (unlines (entries ++ [file]))

cmdCommit :: String -> IO ()
cmdCommit msg = do
    entries <- readIndex
    if null entries
        then putStrLn "Nothing to commit" >> exitFailure
        else do
            let sortedFiles = sort entries
            headContent <- readFileSafe headFile
            let parentHash = let h = stripNewlines headContent in if null h then "NONE" else h
            now <- getPOSIXTime
            let timestamp = show (floor now :: Integer)
            fileEntries <- mapM (\f -> do
                content <- BS.readFile f
                let h = miniHash content
                return (f ++ " " ++ h)
                ) sortedFiles
            let commitContent = unlines $
                    [ "parent: " ++ parentHash
                    , "timestamp: " ++ timestamp
                    , "message: " ++ msg
                    , "files:"
                    ] ++ fileEntries
            let commitHash = miniHash (stringToBS commitContent)
            writeFile (commitsDir ++ "/" ++ commitHash) commitContent
            writeFile headFile commitHash
            writeFile indexFile ""
            putStrLn ("Committed " ++ commitHash)

cmdLog :: IO ()
cmdLog = do
    headContent <- readFileSafe headFile
    let h = stripNewlines headContent
    if null h
        then putStrLn "No commits"
        else printLog h

printLog :: String -> IO ()
printLog hash = do
    content <- readFileStrict (commitsDir ++ "/" ++ hash)
    let ls = lines content
    let timestamp = extractField "timestamp: " ls
    let message = extractField "message: " ls
    let parent = extractField "parent: " ls
    putStrLn ("commit " ++ hash)
    putStrLn ("Date: " ++ timestamp)
    putStrLn ("Message: " ++ message)
    if parent /= "NONE"
        then putStrLn "" >> printLog parent
        else return ()

extractField :: String -> [String] -> String
extractField prefix = maybe "" (drop (length prefix)) . safeHead . filter (isPrefixOf prefix)
  where safeHead (x:_) = Just x
        safeHead []    = Nothing

cmdStatus :: IO ()
cmdStatus = do
    entries <- readIndex
    putStrLn "Staged files:"
    if null entries
        then putStrLn "(none)"
        else mapM_ putStrLn entries

cmdDiff :: String -> String -> IO ()
cmdDiff c1 c2 = do
    exists1 <- doesFileExist (commitsDir ++ "/" ++ c1)
    exists2 <- doesFileExist (commitsDir ++ "/" ++ c2)
    if not (exists1 && exists2)
        then putStrLn "Invalid commit" >> exitFailure
        else do
            content1 <- readFileStrict (commitsDir ++ "/" ++ c1)
            content2 <- readFileStrict (commitsDir ++ "/" ++ c2)
            let files1 = parseCommitFiles (lines content1)
            let files2 = parseCommitFiles (lines content2)
            let allNames = sort $ unique $ map fst files1 ++ map fst files2
            mapM_ (\name -> do
                let h1 = lookup name files1
                let h2 = lookup name files2
                case (h1, h2) of
                    (Nothing, Just _)  -> putStrLn ("Added: " ++ name)
                    (Just _, Nothing)  -> putStrLn ("Removed: " ++ name)
                    (Just a, Just b)   -> if a /= b then putStrLn ("Modified: " ++ name) else return ()
                    _                  -> return ()
                ) allNames
  where
    unique [] = []
    unique (x:xs) = x : unique (filter (/= x) xs)

cmdCheckout :: String -> IO ()
cmdCheckout hash = do
    exists <- doesFileExist (commitsDir ++ "/" ++ hash)
    if not exists
        then putStrLn "Invalid commit" >> exitFailure
        else do
            content <- readFileStrict (commitsDir ++ "/" ++ hash)
            let files = parseCommitFiles (lines content)
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
        then putStrLn "Invalid commit" >> exitFailure
        else do
            writeFile headFile hash
            writeFile indexFile ""
            putStrLn ("Reset to " ++ hash)

cmdRm :: String -> IO ()
cmdRm file = do
    entries <- readIndex
    if file `notElem` entries
        then putStrLn "File not in index" >> exitFailure
        else writeFile indexFile (unlines $ filter (/= file) entries)

cmdShow :: String -> IO ()
cmdShow hash = do
    exists <- doesFileExist (commitsDir ++ "/" ++ hash)
    if not exists
        then putStrLn "Invalid commit" >> exitFailure
        else do
            content <- readFileStrict (commitsDir ++ "/" ++ hash)
            let ls = lines content
            let timestamp = extractField "timestamp: " ls
            let message = extractField "message: " ls
            let files = sort $ parseCommitFiles ls
            putStrLn ("commit " ++ hash)
            putStrLn ("Date: " ++ timestamp)
            putStrLn ("Message: " ++ message)
            putStrLn "Files:"
            mapM_ (\(fname, blobHash) -> putStrLn ("  " ++ fname ++ " " ++ blobHash)) files
