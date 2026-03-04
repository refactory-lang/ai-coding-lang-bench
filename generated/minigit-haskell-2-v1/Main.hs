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
        ("log" : _)                 -> cmdLog
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
