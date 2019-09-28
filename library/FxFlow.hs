module FxFlow
(
  -- * Accessor
  spawn,
  -- * Spawner
  Spawner,
  react,
  -- * Flow
  Flow,
)
where

import FxFlow.Prelude
import qualified Fx


-- * Accessor
-------------------------

{-|
Block running a network of actors until one of the following happens:

- Flow produces the first output;
- An @err@ error gets raised by anything involved;
- An async exception gets raised. That's what `SomeException` stands for.
-}
spawn :: Spawner env err (Flow out) -> Accessor env (Either SomeException err) out
spawn (Spawner reader) = do

  errOrRes <- Fx.use $ \ env -> bimap1 Left $ Fx.io $ do
    
    outChan <- newTQueueIO
    errChan <- newTQueueIO

    -- Spawn all the flow workers:
    (Flow reg, flowKillers) <- runStateT (runReaderT reader (env, atomically . writeTQueue errChan)) []

    -- Register a callback, writing the result
    atomically $ reg $ \ out -> writeTQueue outChan out

    -- Block waiting for error or result:
    errOrRes <- atomically $ Right <$> peekTQueue outChan <|> Left <$> peekTQueue errChan

    -- Kill all forked threads:
    fold flowKillers

    return errOrRes

  either throwError return errOrRes


-- * Spawner
-------------------------

{-|
Context for spawning of actors.
-}
newtype Spawner env err a = Spawner (ReaderT (env, Either SomeException err -> IO ()) (StateT [IO ()] IO) a)
  deriving (Functor, Applicative, Monad)

{-|
Spawn a reactor with an input message buffer of size limited to the specified size,
producing a flow, which outputs results.
-}
react :: Int -> (inp -> Accessor env err out) -> Spawner env err (inp -> Flow out)
react taskQueueSize step = Spawner $ ReaderT $ \ (env, reportErr) -> StateT $ \ priorKillers -> do
  taskQueue <- newTBQueueIO (fromIntegral taskQueueSize)
  deathLockVar <- newEmptyMVar
  forkIO $ fix $ \ loop -> do
    task <- atomically $ readTBQueue taskQueue
    case task of
      Just (inp, emit) -> do
        errOrOut <- Fx.uio $ runExceptT $ Fx.eio $ Fx.providerAndAccessor (pure env) $ step inp
        case errOrOut of
          Right out -> do
            atomically (emit out)
            loop
          Left err -> do
            reportErr (Right err)
            tryPutMVar deathLockVar () $> ()
      Nothing -> tryPutMVar deathLockVar () $> ()
  let
    flow inp = Flow (\ emit -> writeTBQueue taskQueue (Just (inp, emit)))
    kill = do
      atomically (writeTBQueue taskQueue Nothing)
      readMVar deathLockVar
    newKillers = kill : priorKillers
    in return (flow, newKillers)


-- * Flow
-------------------------

{-|
Actor communication network composition.
Specifies the message flow between them.
-}
newtype Flow a =
  {-|
  Action registering a callback.

  The idea is that the outer action is lightweight
  it deals with composition and message registration.
  The continuation action is lightweight aswell,
  it just gets executed on a different thread some time later on.
  -}
  Flow ((a -> STM ()) -> STM ())
  deriving (Functor)

instance Applicative Flow where
  pure a = Flow (\ emit -> emit a)
  (<*>) (Flow reg1) (Flow reg2) = Flow $ \ emit -> do
    var1 <- newTVar Nothing
    var2 <- newTVar Nothing
    reg1 $ \ out1 -> do
      state2 <- readTVar var2
      case state2 of
        Just out2 -> emit (out1 out2)
        Nothing -> writeTVar var1 (Just out1)
    reg2 $ \ out2 -> do
      state1 <- readTVar var1
      case state1 of
        Just out1 -> emit (out1 out2)
        Nothing -> writeTVar var2 (Just out2)

instance Monad Flow where
  return = pure
  (>>=) (Flow reg1) k2 = Flow $ \ emit -> reg1 $ k2 >>> \ (Flow reg2) -> reg2 emit

instance Alternative Flow where
  empty = Flow (\ emit -> return ())
  (<|>) (Flow reg1) (Flow reg2) = Flow $ \ emit -> reg1 emit *> reg2 emit

instance MonadPlus Flow where
  mzero = empty
  mplus = (<|>)
