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
        ["log"] -> cmdLog
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
            indexContent <- readFile ".minigit/index"
            let entries = if null indexContent then [] else lines indexContent
            if file `elem` entries
                then return ()
                else writeFile ".minigit/index" (unlines (entries ++ [file]))

cmdCommit :: String -> IO ()
cmdCommit msg = do
    indexContent <- readFile ".minigit/index"
    let entries = filter (not . null) (lines indexContent)
    if null entries
        then do
            putStrLn "Nothing to commit"
            exitFailure
        else do
            headContent <- readFile ".minigit/HEAD"
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
    headContent <- readFile ".minigit/HEAD"
    if null headContent
        then putStrLn "No commits"
        else printLog headContent

printLog :: String -> IO ()
printLog hash = do
    let path = ".minigit/commits/" ++ hash
    content <- readFile path
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
