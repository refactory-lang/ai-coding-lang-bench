module Main where

import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist)
import Data.Word (Word8, Word64)
import Data.Bits (xor)
import Data.List (sort, intercalate)
import qualified Data.ByteString as BS
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
        ["log"] -> cmdLog
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
        then putStrLn "Nothing to commit" >> exitFailure
        else do
            headContent <- readFile headFile
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
    headContent <- readFile headFile
    if null headContent
        then putStrLn "No commits"
        else printLog headContent

printLog :: String -> IO ()
printLog hash = do
    content <- readFile (commitsDir ++ "/" ++ hash)
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
