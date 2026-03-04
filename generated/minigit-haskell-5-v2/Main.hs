module Main where

import System.Environment (getArgs)
import System.Directory (createDirectoryIfMissing, doesFileExist, doesDirectoryExist)
import System.Exit (exitFailure, exitSuccess)
import Data.Word (Word64, Word8)
import Data.Bits (xor)
import Data.List (sort, nub)
import qualified Data.ByteString as BS
import Numeric (showHex)
import Data.Char (chr)
import System.Posix.Time (epochTime)

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

miniHash :: BS.ByteString -> String
miniHash bs = padLeft 16 '0' $ showHex result ""
  where
    result = BS.foldl' step 1469598103934665603 bs
    step :: Word64 -> Word8 -> Word64
    step h b = (h `xor` fromIntegral b) * 1099511628211

padLeft :: Int -> Char -> String -> String
padLeft n c s
  | length s >= n = s
  | otherwise = replicate (n - length s) c ++ s

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
            -- Read current index and add if not present
            idx <- readFile indexFile
            let entries = filter (not . null) (lines idx)
            if file `elem` entries
                then return ()
                else writeFile indexFile (unlines (entries ++ [file]))

cmdCommit :: String -> IO ()
cmdCommit msg = do
    idx <- readFile indexFile
    let entries = filter (not . null) (lines idx)
    if null entries
        then do
            putStrLn "Nothing to commit"
            exitFailure
        else do
            -- Get parent
            headContent <- readFile headFile
            let parent = if null headContent then "NONE" else headContent
            -- Get timestamp
            epoch <- epochTime
            let timestamp = show (fromEnum epoch)
            -- Build file entries: for each file, compute its blob hash
            fileHashes <- mapM (\f -> do
                content <- BS.readFile f
                let hash = miniHash content
                return (f, hash)
                ) (sort entries)
            let filesSection = concatMap (\(f, h) -> f ++ " " ++ h ++ "\n") fileHashes
            let commitContent = "parent: " ++ parent ++ "\n"
                             ++ "timestamp: " ++ timestamp ++ "\n"
                             ++ "message: " ++ msg ++ "\n"
                             ++ "files:\n"
                             ++ filesSection
            let commitHash = miniHash (BS.pack (map (fromIntegral . fromEnum) commitContent))
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
    let commitPath = commitsDir ++ "/" ++ hash
    content <- readFile commitPath
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
    case filter (\l -> take (length prefix) l == prefix) ls of
        (x:_) -> drop (length prefix) x
        [] -> ""

parseCommitFiles :: [String] -> [(String, String)]
parseCommitFiles ls =
    let afterFiles = drop 1 (dropWhile (/= "files:") ls)
    in map parseFileLine (filter (not . null) afterFiles)
  where
    parseFileLine l = let (name, rest) = break (== ' ') l
                      in (name, drop 1 rest)

cmdStatus :: IO ()
cmdStatus = do
    idx <- readFile indexFile
    let entries = filter (not . null) (lines idx)
    putStrLn "Staged files:"
    if null entries
        then putStrLn "(none)"
        else mapM_ putStrLn entries

cmdDiff :: String -> String -> IO ()
cmdDiff c1 c2 = do
    let path1 = commitsDir ++ "/" ++ c1
    let path2 = commitsDir ++ "/" ++ c2
    e1 <- doesFileExist path1
    e2 <- doesFileExist path2
    if not e1 || not e2
        then do
            putStrLn "Invalid commit"
            exitFailure
        else do
            content1 <- readFile path1
            content2 <- readFile path2
            let files1 = parseCommitFiles (lines content1)
            let files2 = parseCommitFiles (lines content2)
            let allNames = sort $ nub (map fst files1 ++ map fst files2)
            mapM_ (\name -> do
                let h1 = lookup name files1
                let h2 = lookup name files2
                case (h1, h2) of
                    (Nothing, Just _)  -> putStrLn ("Added: " ++ name)
                    (Just _, Nothing)  -> putStrLn ("Removed: " ++ name)
                    (Just a, Just b)   -> if a /= b then putStrLn ("Modified: " ++ name) else return ()
                    _ -> return ()
                ) allNames

cmdCheckout :: String -> IO ()
cmdCheckout hash = do
    let path = commitsDir ++ "/" ++ hash
    exists <- doesFileExist path
    if not exists
        then do
            putStrLn "Invalid commit"
            exitFailure
        else do
            content <- readFile path
            let files = parseCommitFiles (lines content)
            mapM_ (\(name, blobHash) -> do
                blob <- BS.readFile (objectsDir ++ "/" ++ blobHash)
                BS.writeFile name blob
                ) files
            writeFile headFile hash
            writeFile indexFile ""
            putStrLn ("Checked out " ++ hash)

cmdReset :: String -> IO ()
cmdReset hash = do
    let path = commitsDir ++ "/" ++ hash
    exists <- doesFileExist path
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
    idx <- BS.readFile indexFile
    let entries = filter (not . null) (lines (map (chr . fromIntegral) (BS.unpack idx)))
    if file `elem` entries
        then writeFile indexFile (unlines (filter (/= file) entries))
        else do
            putStrLn "File not in index"
            exitFailure

cmdShow :: String -> IO ()
cmdShow hash = do
    let path = commitsDir ++ "/" ++ hash
    exists <- doesFileExist path
    if not exists
        then do
            putStrLn "Invalid commit"
            exitFailure
        else do
            content <- readFile path
            let ls = lines content
            let timestamp = extractField "timestamp: " ls
            let message = extractField "message: " ls
            let files = parseCommitFiles ls
            putStrLn ("commit " ++ hash)
            putStrLn ("Date: " ++ timestamp)
            putStrLn ("Message: " ++ message)
            putStrLn "Files:"
            mapM_ (\(name, blobHash) -> putStrLn ("  " ++ name ++ " " ++ blobHash)) (sort files)
