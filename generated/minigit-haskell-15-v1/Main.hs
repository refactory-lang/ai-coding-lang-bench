module Main where

import System.Environment (getArgs)
import System.Directory (createDirectoryIfMissing, doesFileExist, doesDirectoryExist)
import System.Exit (exitFailure, exitSuccess)
import Data.Word (Word64, Word8)
import Data.Bits (xor)
import Data.List (sort, nub)
import Data.Char (intToDigit)
import qualified Data.ByteString as BS

miniHash :: BS.ByteString -> String
miniHash bs = toHex16 final
  where
    initial :: Word64
    initial = 1469598103934665603
    final = BS.foldl' step initial bs
    step :: Word64 -> Word8 -> Word64
    step h b = (h `xor` fromIntegral b) * 1099511628211

toHex16 :: Word64 -> String
toHex16 w = map hexDigit [60,56..0]
  where
    hexDigit shift = intToDigit (fromIntegral ((w `div` (2^shift)) `mod` 16))

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
    content <- readFile (".minigit/commits/" ++ hash)
    let ls = lines content
        parentLine = head ls
        timestampLine = ls !! 1
        messageLine = ls !! 2
        parent = drop 8 parentLine  -- "parent: " is 8 chars
        timestamp = drop 11 timestampLine  -- "timestamp: " is 11 chars
        message = drop 9 messageLine  -- "message: " is 9 chars
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
    -- Read /proc/stat... no, let's use Data.Time or System.Posix
    -- We can't use external libraries. Let's use foreign import or read the clock.
    -- Simplest: use System.Posix.Time
    -- Actually, let's just call date +%s via System.Process... but that's stdlib.
    -- System.Posix is part of the unix package which ships with GHC.
    -- Let's use it.
    t <- getPOSIXTime
    return (show (floor t :: Integer))

-- We need to get POSIX time without importing extra modules at the top.
-- Let's use a foreign import instead.

foreign import ccall "time" c_time :: IO Int

getPOSIXTime :: IO Double
getPOSIXTime = do
    t <- c_time
    return (fromIntegral t)

strToBS :: String -> BS.ByteString
strToBS = BS.pack . map (fromIntegral . fromEnum)
