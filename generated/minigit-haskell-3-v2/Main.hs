module Main where

import System.Environment (getArgs)
import System.Directory (doesDirectoryExist, doesFileExist, createDirectoryIfMissing)
import System.Exit (exitFailure)
import Data.Word (Word64)
import Data.Bits (xor)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as C8
import Data.List (sort, isPrefixOf, nub)
import Numeric (showHex)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Control.Monad (when)

miniHash :: BS.ByteString -> String
miniHash bs = replicate (16 - length hex) '0' ++ hex
  where
    h = BS.foldl' step (1469598103934665603 :: Word64) bs
    step acc b = (acc `xor` fromIntegral b) * 1099511628211
    hex = showHex h ""

readStrict :: FilePath -> IO String
readStrict p = C8.unpack <$> BS.readFile p

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
        _ -> putStrLn "Unknown command" >> exitFailure

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
cmdAdd filename = do
    exists <- doesFileExist filename
    if not exists
        then putStrLn "File not found" >> exitFailure
        else do
            content <- BS.readFile filename
            let hash = miniHash content
            BS.writeFile (".minigit/objects/" ++ hash) content
            idxStr <- readStrict ".minigit/index"
            let entries = filter (not . null) (lines idxStr)
            when (filename `notElem` entries) $
                writeFile ".minigit/index" (unlines (entries ++ [filename]))

cmdCommit :: String -> IO ()
cmdCommit message = do
    idxStr <- readStrict ".minigit/index"
    let entries = filter (not . null) (lines idxStr)
    if null entries
        then putStrLn "Nothing to commit" >> exitFailure
        else do
            headStr <- filter (\c -> c /= '\n' && c /= '\r') <$> readStrict ".minigit/HEAD"
            let parent = if null headStr then "NONE" else headStr
            t <- getPOSIXTime
            let timestamp = show (round t :: Integer)
                sortedFiles = sort entries
            fileLines <- mapM (\f -> do
                content <- BS.readFile f
                return (f ++ " " ++ miniHash content)) sortedFiles
            let commitStr = unlines $
                    [ "parent: " ++ parent
                    , "timestamp: " ++ timestamp
                    , "message: " ++ message
                    , "files:" ] ++ fileLines
                commitBS = C8.pack commitStr
                commitHash = miniHash commitBS
            C8.writeFile (".minigit/commits/" ++ commitHash) commitBS
            writeFile ".minigit/HEAD" commitHash
            writeFile ".minigit/index" ""
            putStrLn ("Committed " ++ commitHash)

cmdStatus :: IO ()
cmdStatus = do
    idxStr <- readStrict ".minigit/index"
    let entries = filter (not . null) (lines idxStr)
    putStrLn "Staged files:"
    if null entries
        then putStrLn "(none)"
        else mapM_ putStrLn entries

cmdLog :: IO ()
cmdLog = do
    headStr <- filter (\c -> c /= '\n' && c /= '\r') <$> readStrict ".minigit/HEAD"
    if null headStr
        then putStrLn "No commits"
        else printLog headStr
  where
    printLog hash = do
        content <- readStrict (".minigit/commits/" ++ hash)
        let ls = lines content
            getField prefix = drop (length prefix) $ head $ filter (isPrefixOf prefix) ls
            parent = getField "parent: "
            timestamp = getField "timestamp: "
            msg = getField "message: "
        putStrLn ("commit " ++ hash)
        putStrLn ("Date: " ++ timestamp)
        putStrLn ("Message: " ++ msg)
        when (parent /= "NONE") $ do
            putStrLn ""
            printLog parent

parseCommitFiles :: String -> [(String, String)]
parseCommitFiles content =
    let ls = lines content
        afterFiles = drop 1 $ dropWhile (/= "files:") ls
        parseLine l = case words l of
            [fname, hash] -> Just (fname, hash)
            _ -> Nothing
    in sort [ (f, h) | Just (f, h) <- map parseLine afterFiles ]

cmdDiff :: String -> String -> IO ()
cmdDiff c1 c2 = do
    e1 <- doesFileExist (".minigit/commits/" ++ c1)
    e2 <- doesFileExist (".minigit/commits/" ++ c2)
    if not (e1 && e2)
        then putStrLn "Invalid commit" >> exitFailure
        else do
            content1 <- readStrict (".minigit/commits/" ++ c1)
            content2 <- readStrict (".minigit/commits/" ++ c2)
            let files1 = parseCommitFiles content1
                files2 = parseCommitFiles content2
                allNames = sort $ nub $ map fst files1 ++ map fst files2
            mapM_ (\name ->
                case (lookup name files1, lookup name files2) of
                    (Nothing, Just _)  -> putStrLn ("Added: " ++ name)
                    (Just _, Nothing)  -> putStrLn ("Removed: " ++ name)
                    (Just h1, Just h2) -> when (h1 /= h2) $ putStrLn ("Modified: " ++ name)
                    _ -> return ()
                ) allNames

cmdCheckout :: String -> IO ()
cmdCheckout hash = do
    exists <- doesFileExist (".minigit/commits/" ++ hash)
    if not exists
        then putStrLn "Invalid commit" >> exitFailure
        else do
            content <- readStrict (".minigit/commits/" ++ hash)
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
    exists <- doesFileExist (".minigit/commits/" ++ hash)
    if not exists
        then putStrLn "Invalid commit" >> exitFailure
        else do
            writeFile ".minigit/HEAD" hash
            writeFile ".minigit/index" ""
            putStrLn ("Reset to " ++ hash)

cmdRm :: String -> IO ()
cmdRm filename = do
    idxStr <- readStrict ".minigit/index"
    let entries = filter (not . null) (lines idxStr)
    if filename `notElem` entries
        then putStrLn "File not in index" >> exitFailure
        else writeFile ".minigit/index" (unlines (filter (/= filename) entries))

cmdShow :: String -> IO ()
cmdShow hash = do
    exists <- doesFileExist (".minigit/commits/" ++ hash)
    if not exists
        then putStrLn "Invalid commit" >> exitFailure
        else do
            content <- readStrict (".minigit/commits/" ++ hash)
            let ls = lines content
                getField prefix = drop (length prefix) $ head $ filter (isPrefixOf prefix) ls
                timestamp = getField "timestamp: "
                msg = getField "message: "
                files = parseCommitFiles content
            putStrLn ("commit " ++ hash)
            putStrLn ("Date: " ++ timestamp)
            putStrLn ("Message: " ++ msg)
            putStrLn "Files:"
            mapM_ (\(fname, blobHash) -> putStrLn ("  " ++ fname ++ " " ++ blobHash)) files
