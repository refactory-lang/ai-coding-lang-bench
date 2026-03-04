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
        ["log"] -> cmdLog
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
            idx <- readFile ".minigit/index"
            let entries = filter (not . null) (lines idx)
            if file `elem` entries
                then return ()
                else writeFile ".minigit/index" (unlines (entries ++ [file]))

cmdCommit :: String -> IO ()
cmdCommit msg = do
    idx <- readFile ".minigit/index"
    let entries = filter (not . null) (lines idx)
    if null entries
        then do
            putStrLn "Nothing to commit"
            exitWith (ExitFailure 1)
        else do
            headContent <- readFile ".minigit/HEAD"
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
    headContent <- readFile ".minigit/HEAD"
    if null headContent
        then putStrLn "No commits"
        else walkLog headContent

walkLog :: String -> IO ()
walkLog hash = do
    content <- readFile (".minigit/commits/" ++ hash)
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

extractField :: String -> [String] -> String
extractField prefix ls =
    case filter (isPrefixOf prefix) ls of
        (x:_) -> drop (length prefix) x
        [] -> ""

stringToBS :: String -> BS.ByteString
stringToBS = BS.pack . map (fromIntegral . fromEnum)
